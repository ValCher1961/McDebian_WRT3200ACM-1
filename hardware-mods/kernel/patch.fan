Armada 370/XP devices can 'blink' gpio lines with a configurable on
and off period. This can be modelled as a PWM.

However, there are only two sets of PWM configuration registers for
all the gpio lines. This driver simply allows a single gpio line per
gpio chip of 32 lines to be used as a PWM. Attempts to use more return
EBUSY.

Due to the interleaving of registers it is not simple to separate the
PWM driver from the gpio driver. Thus the gpio driver has been
extended with a PWM driver.

Signed-off-by: Andrew Lunn <andrew@lunn.ch>
---
 drivers/gpio/Kconfig          |   5 ++
 drivers/gpio/Makefile         |   1 +
 drivers/gpio/gpio-mvebu-pwm.c | 202 ++++++++++++++++++++++++++++++++++++++++++
 drivers/gpio/gpio-mvebu.c     |  37 +++-----
 drivers/gpio/gpio-mvebu.h     |  79 +++++++++++++++++
 5 files changed, 299 insertions(+), 25 deletions(-)
 create mode 100644 drivers/gpio/gpio-mvebu-pwm.c
 create mode 100644 drivers/gpio/gpio-mvebu.h

--- a/drivers/gpio/Kconfig
+++ b/drivers/gpio/Kconfig
@@ -246,6 +246,11 @@ config GPIO_MVEBU
 	select GPIO_GENERIC
 	select GENERIC_IRQ_CHIP
 
+config GPIO_MVEBU_PWM
+	def_bool y
+	depends on GPIO_MVEBU
+	depends on PWM
+
 config GPIO_MXC
 	def_bool y
 	depends on ARCH_MXC
--- a/drivers/gpio/Makefile
+++ b/drivers/gpio/Makefile
@@ -61,6 +61,7 @@ obj-$(CONFIG_GPIO_MSIC)		+= gpio-msic.o
 obj-$(CONFIG_GPIO_MSM_V1)	+= gpio-msm-v1.o
 obj-$(CONFIG_GPIO_MSM_V2)	+= gpio-msm-v2.o
 obj-$(CONFIG_GPIO_MVEBU)        += gpio-mvebu.o
+obj-$(CONFIG_GPIO_MVEBU_PWM)	+= gpio-mvebu-pwm.o
 obj-$(CONFIG_GPIO_MXC)		+= gpio-mxc.o
 obj-$(CONFIG_GPIO_MXS)		+= gpio-mxs.o
 obj-$(CONFIG_GPIO_OCTEON)	+= gpio-octeon.o
--- /dev/null
+++ b/drivers/gpio/gpio-mvebu-pwm.c
@@ -0,0 +1,202 @@
+#include <linux/err.h>
+#include <linux/module.h>
+#include <linux/gpio.h>
+#include <linux/pwm.h>
+#include <linux/clk.h>
+#include <linux/platform_device.h>
+#include "gpio-mvebu.h"
+#include "gpiolib.h"
+
+static void __iomem *mvebu_gpioreg_blink_select(struct mvebu_gpio_chip *mvchip)
+{
+	return mvchip->membase + GPIO_BLINK_CNT_SELECT;
+}
+
+static inline struct mvebu_pwm *to_mvebu_pwm(struct pwm_chip *chip)
+{
+	return container_of(chip, struct mvebu_pwm, chip);
+}
+
+static inline struct mvebu_gpio_chip *to_mvchip(struct mvebu_pwm *pwm)
+{
+	return container_of(pwm, struct mvebu_gpio_chip, pwm);
+}
+
+static int mvebu_pwm_request(struct pwm_chip *chip, struct pwm_device *pwmd)
+{
+	struct mvebu_pwm *pwm = to_mvebu_pwm(chip);
+	struct mvebu_gpio_chip *mvchip = to_mvchip(pwm);
+	struct gpio_desc *desc = gpio_to_desc(pwmd->pwm);
+	unsigned long flags;
+	int ret = 0;
+
+	spin_lock_irqsave(&pwm->lock, flags);
+	if (pwm->used) {
+		ret = -EBUSY;
+	} else {
+		if (!desc) {
+			ret = -ENODEV;
+			goto out;
+		}
+		ret = gpiod_request(desc, "mvebu-pwm");
+		if (ret)
+			goto out;
+
+		ret = gpiod_direction_output(desc, 0);
+		if (ret) {
+			gpiod_free(desc);
+			goto out;
+		}
+
+		pwm->pin = pwmd->pwm - mvchip->chip.base;
+		pwm->used = true;
+	}
+
+out:
+	spin_unlock_irqrestore(&pwm->lock, flags);
+	return ret;
+}
+
+static void mvebu_pwm_free(struct pwm_chip *chip, struct pwm_device *pwmd)
+{
+	struct mvebu_pwm *pwm = to_mvebu_pwm(chip);
+	struct gpio_desc *desc = gpio_to_desc(pwmd->pwm);
+	unsigned long flags;
+
+	spin_lock_irqsave(&pwm->lock, flags);
+	gpiod_free(desc);
+	pwm->used = false;
+	spin_unlock_irqrestore(&pwm->lock, flags);
+}
+
+static int mvebu_pwm_config(struct pwm_chip *chip, struct pwm_device *pwmd,
+			    int duty_ns, int period_ns)
+{
+	struct mvebu_pwm *pwm = to_mvebu_pwm(chip);
+	struct mvebu_gpio_chip *mvchip = to_mvchip(pwm);
+	unsigned int on, off;
+	unsigned long long val;
+	u32 u;
+
+	val = (unsigned long long) pwm->clk_rate * duty_ns;
+	do_div(val, NSEC_PER_SEC);
+	if (val > UINT_MAX)
+		return -EINVAL;
+	if (val)
+		on = val;
+	else
+		on = 1;
+
+	val = (unsigned long long) pwm->clk_rate * (period_ns - duty_ns);
+	do_div(val, NSEC_PER_SEC);
+	if (val > UINT_MAX)
+		return -EINVAL;
+	if (val)
+		off = val;
+	else
+		off = 1;
+
+	u = readl_relaxed(mvebu_gpioreg_blink_select(mvchip));
+	u &= ~(1 << pwm->pin);
+	u |= (pwm->id << pwm->pin);
+	writel_relaxed(u, mvebu_gpioreg_blink_select(mvchip));
+
+	writel_relaxed(on, pwm->membase + BLINK_ON_DURATION);
+	writel_relaxed(off, pwm->membase + BLINK_OFF_DURATION);
+
+	return 0;
+}
+
+static int mvebu_pwm_enable(struct pwm_chip *chip, struct pwm_device *pwmd)
+{
+	struct mvebu_pwm *pwm = to_mvebu_pwm(chip);
+	struct mvebu_gpio_chip *mvchip = to_mvchip(pwm);
+
+	mvebu_gpio_blink(&mvchip->chip, pwm->pin, 1);
+
+	return 0;
+}
+
+static void mvebu_pwm_disable(struct pwm_chip *chip, struct pwm_device *pwmd)
+{
+	struct mvebu_pwm *pwm = to_mvebu_pwm(chip);
+	struct mvebu_gpio_chip *mvchip = to_mvchip(pwm);
+
+	mvebu_gpio_blink(&mvchip->chip, pwm->pin, 0);
+}
+
+static const struct pwm_ops mvebu_pwm_ops = {
+	.request = mvebu_pwm_request,
+	.free = mvebu_pwm_free,
+	.config = mvebu_pwm_config,
+	.enable = mvebu_pwm_enable,
+	.disable = mvebu_pwm_disable,
+	.owner = THIS_MODULE,
+};
+
+void mvebu_pwm_suspend(struct mvebu_gpio_chip *mvchip)
+{
+	struct mvebu_pwm *pwm = &mvchip->pwm;
+
+	pwm->blink_select = readl_relaxed(mvebu_gpioreg_blink_select(mvchip));
+	pwm->blink_on_duration =
+		readl_relaxed(pwm->membase + BLINK_ON_DURATION);
+	pwm->blink_off_duration =
+		readl_relaxed(pwm->membase + BLINK_OFF_DURATION);
+}
+
+void mvebu_pwm_resume(struct mvebu_gpio_chip *mvchip)
+{
+	struct mvebu_pwm *pwm = &mvchip->pwm;
+
+	writel_relaxed(pwm->blink_select, mvebu_gpioreg_blink_select(mvchip));
+	writel_relaxed(pwm->blink_on_duration,
+		       pwm->membase + BLINK_ON_DURATION);
+	writel_relaxed(pwm->blink_off_duration,
+		       pwm->membase + BLINK_OFF_DURATION);
+}
+
+/*
+ * Armada 370/XP has simple PWM support for gpio lines. Other SoCs
+ * don't have this hardware. So if we don't have the necessary
+ * resource, it is not an error.
+ */
+int mvebu_pwm_probe(struct platform_device *pdev,
+		    struct mvebu_gpio_chip *mvchip,
+		    int id)
+{
+	struct device *dev = &pdev->dev;
+	struct mvebu_pwm *pwm = &mvchip->pwm;
+	struct resource *res;
+
+	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "pwm");
+	if (!res)
+		return 0;
+
+	mvchip->pwm.membase = devm_ioremap_resource(&pdev->dev, res);
+	if (IS_ERR(mvchip->pwm.membase))
+		return PTR_ERR(mvchip->percpu_membase);
+
+	if (id < 0 || id > 1)
+		return -EINVAL;
+	pwm->id = id;
+
+	if (IS_ERR(mvchip->clk))
+		return PTR_ERR(mvchip->clk);
+
+	pwm->clk_rate = clk_get_rate(mvchip->clk);
+	if (!pwm->clk_rate) {
+		dev_err(dev, "failed to get clock rate\n");
+		return -EINVAL;
+	}
+
+	pwm->chip.dev = dev;
+	pwm->chip.ops = &mvebu_pwm_ops;
+	pwm->chip.base = mvchip->chip.base;
+	pwm->chip.npwm = mvchip->chip.ngpio;
+	pwm->chip.can_sleep = false;
+
+	spin_lock_init(&pwm->lock);
+
+	return pwmchip_add(&pwm->chip);
+}
--- a/drivers/gpio/gpio-mvebu.c
+++ b/drivers/gpio/gpio-mvebu.c
@@ -42,10 +42,11 @@
 #include <linux/io.h>
 #include <linux/of_irq.h>
 #include <linux/of_device.h>
+#include <linux/pwm.h>
 #include <linux/clk.h>
 #include <linux/pinctrl/consumer.h>
 #include <linux/irqchip/chained_irq.h>
-
+#include "gpio-mvebu.h"
 /*
  * GPIO unit register offsets.
  */
@@ -75,24 +76,6 @@
 
 #define MVEBU_MAX_GPIO_PER_BANK		32
 
-struct mvebu_gpio_chip {
-	struct gpio_chip   chip;
-	spinlock_t	   lock;
-	void __iomem	  *membase;
-	void __iomem	  *percpu_membase;
-	int		   irqbase;
-	struct irq_domain *domain;
-	int		   soc_variant;
-
-	/* Used to preserve GPIO registers across suspend/resume */
-	u32                out_reg;
-	u32                io_conf_reg;
-	u32                blink_en_reg;
-	u32                in_pol_reg;
-	u32                edge_mask_regs[4];
-	u32                level_mask_regs[4];
-};
-
 /*
  * Functions returning addresses of individual registers for a given
  * GPIO controller.
@@ -228,7 +211,7 @@ static int mvebu_gpio_get(struct gpio_ch
 	return (u >> pin) & 1;
 }
 
-static void mvebu_gpio_blink(struct gpio_chip *chip, unsigned pin, int value)
+void mvebu_gpio_blink(struct gpio_chip *chip, unsigned pin, int value)
 {
 	struct mvebu_gpio_chip *mvchip =
 		container_of(chip, struct mvebu_gpio_chip, chip);
@@ -617,6 +600,8 @@ static int mvebu_gpio_suspend(struct pla
 		BUG();
 	}
 
+	mvebu_pwm_suspend(mvchip);
+
 	return 0;
 }
 
@@ -660,6 +645,8 @@ static int mvebu_gpio_resume(struct plat
 		BUG();
 	}
 
+	mvebu_pwm_resume(mvchip);
+
 	return 0;
 }
 
@@ -671,7 +658,6 @@ static int mvebu_gpio_probe(struct platf
 	struct resource *res;
 	struct irq_chip_generic *gc;
 	struct irq_chip_type *ct;
-	struct clk *clk;
 	unsigned int ngpios;
 	int soc_variant;
 	int i, cpu, id;
@@ -701,10 +687,10 @@ static int mvebu_gpio_probe(struct platf
 		return id;
 	}
 
-	clk = devm_clk_get(&pdev->dev, NULL);
+	mvchip->clk = devm_clk_get(&pdev->dev, NULL);
 	/* Not all SoCs require a clock.*/
-	if (!IS_ERR(clk))
-		clk_prepare_enable(clk);
+	if (!IS_ERR(mvchip->clk))
+		clk_prepare_enable(mvchip->clk);
 
 	mvchip->soc_variant = soc_variant;
 	mvchip->chip.label = dev_name(&pdev->dev);
@@ -838,7 +824,8 @@ static int mvebu_gpio_probe(struct platf
 		goto err_generic_chip;
 	}
 
-	return 0;
+	/* Armada 370/XP has simple PWM support for gpio lines */
+	return mvebu_pwm_probe(pdev, mvchip, id);
 
 err_generic_chip:
 	irq_remove_generic_chip(gc, IRQ_MSK(ngpios), IRQ_NOREQUEST,
--- /dev/null
+++ b/drivers/gpio/gpio-mvebu.h
@@ -0,0 +1,79 @@
+/*
+ * Interface between MVEBU GPIO driver and PWM driver for GPIO pins
+ *
+ * Copyright (C) 2015, Andrew Lunn <andrew@lunn.ch>
+ *
+ * This program is free software; you can redistribute it and/or modify
+ * it under the terms of the GNU General Public License version 2 as
+ * published by the Free Software Foundation.
+ */
+
+#ifndef MVEBU_GPIO_PWM_H
+#define MVEBU_GPIO_PWM_H
+
+#define BLINK_ON_DURATION	0x0
+#define BLINK_OFF_DURATION	0x4
+#define GPIO_BLINK_CNT_SELECT	0x0020
+
+struct mvebu_pwm {
+	void __iomem	*membase;
+	unsigned long	 clk_rate;
+	bool		 used;
+	unsigned	 pin;
+	struct pwm_chip	 chip;
+	int		 id;
+	spinlock_t	 lock;
+
+	/* Used to preserve GPIO/PWM registers across suspend /
+	 * resume */
+	u32		 blink_select;
+	u32		 blink_on_duration;
+	u32		 blink_off_duration;
+};
+
+struct mvebu_gpio_chip {
+	struct gpio_chip   chip;
+	spinlock_t	   lock;
+	void __iomem	  *membase;
+	void __iomem	  *percpu_membase;
+	int		   irqbase;
+	struct irq_domain *domain;
+	int		   soc_variant;
+	struct clk	  *clk;
+#ifdef CONFIG_PWM
+	struct mvebu_pwm pwm;
+#endif
+	/* Used to preserve GPIO registers across suspend/resume */
+	u32		   out_reg;
+	u32		   io_conf_reg;
+	u32		   blink_en_reg;
+	u32		   in_pol_reg;
+	u32		   edge_mask_regs[4];
+	u32		   level_mask_regs[4];
+};
+
+void mvebu_gpio_blink(struct gpio_chip *chip, unsigned pin, int value);
+
+#ifdef CONFIG_PWM
+int mvebu_pwm_probe(struct platform_device *pdev,
+		    struct mvebu_gpio_chip *mvchip,
+		    int id);
+void mvebu_pwm_suspend(struct mvebu_gpio_chip *mvchip);
+void mvebu_pwm_resume(struct mvebu_gpio_chip *mvchip);
+#else
+int mvebu_pwm_probe(struct platform_device *pdev,
+		    struct mvebu_gpio_chip *mvchip,
+		    int id)
+{
+	return 0;
+}
+
+void mvebu_pwm_suspend(struct mvebu_gpio_chip *mvchip)
+{
+}
+
+void mvebu_pwm_resume(struct mvebu_gpio_chip *mvchip)
+{
+}
+#endif
+#endif
Document the optional parameters needed for PWM operation of gpio
lines.

Signed-off-by: Andrew Lunn <andrew@lunn.ch>
---
 .../devicetree/bindings/gpio/gpio-mvebu.txt        | 31 ++++++++++++++++++++++
 1 file changed, 31 insertions(+)

--- a/Documentation/devicetree/bindings/gpio/gpio-mvebu.txt
+++ b/Documentation/devicetree/bindings/gpio/gpio-mvebu.txt
@@ -38,6 +38,23 @@ Required properties:
 - #gpio-cells: Should be two. The first cell is the pin number. The
   second cell is reserved for flags, unused at the moment.
 
+Optional properties:
+
+In order to use the gpio lines in PWM mode, some additional optional
+properties are required. Only Armada 370 and XP supports these
+properties.
+
+- reg: an additional register set is needed, for the GPIO Blink
+  Counter on/off registers.
+
+- reg-names: Must contain an entry "pwm" corresponding to the
+  additional register range needed for pwm operation.
+
+- #pwm-cells: Should be two. The first cell is the pin number. The
+  second cell is reserved for flags, unused at the moment.
+
+- clocks: Must be a phandle to the clock for the gpio controller.
+
 Example:
 
 		gpio0: gpio@d0018100 {
@@ -51,3 +68,17 @@ Example:
 			#interrupt-cells = <2>;
 			interrupts = <16>, <17>, <18>, <19>;
 		};
+
+		gpio1: gpio@18140 {
+			compatible = "marvell,orion-gpio";
+			reg = <0x18140 0x40>, <0x181c8 0x08>;
+			reg-names = "gpio", "pwm";
+			ngpios = <17>;
+			gpio-controller;
+			#gpio-cells = <2>;
+			#pwm-cells = <2>;
+			interrupt-controller;
+			#interrupt-cells = <2>;
+			interrupts = <87>, <88>, <89>;
+			clocks = <&coreclk 0>;
+		};
Add properties to the gpio nodes to allow them to be also used
as pwm lines.

Signed-off-by: Andrew Lunn <andrew@lunn.ch>
---
 arch/arm/boot/dts/armada-370.dtsi        | 10 ++++++++--
 arch/arm/boot/dts/armada-xp-mv78230.dtsi | 10 ++++++++--
 arch/arm/boot/dts/armada-xp-mv78260.dtsi |  8 ++++++--
 arch/arm/boot/dts/armada-xp-mv78460.dtsi | 10 ++++++++--
 4 files changed, 30 insertions(+), 8 deletions(-)

--- a/arch/arm/boot/dts/armada-370.dtsi
+++ b/arch/arm/boot/dts/armada-370.dtsi
@@ -157,24 +157,30 @@
 
 			gpio0: gpio@18100 {
 				compatible = "marvell,orion-gpio";
-				reg = <0x18100 0x40>;
+				reg = <0x18100 0x40>, <0x181c0 0x08>;
+				reg-names = "gpio", "pwm";
 				ngpios = <32>;
 				gpio-controller;
 				#gpio-cells = <2>;
+				#pwm-cells = <2>;
 				interrupt-controller;
 				#interrupt-cells = <2>;
 				interrupts = <82>, <83>, <84>, <85>;
+				clocks = <&coreclk 0>;
 			};
 
 			gpio1: gpio@18140 {
 				compatible = "marvell,orion-gpio";
-				reg = <0x18140 0x40>;
+				reg = <0x18140 0x40>, <0x181c8 0x08>;
+				reg-names = "gpio", "pwm";
 				ngpios = <32>;
 				gpio-controller;
 				#gpio-cells = <2>;
+				#pwm-cells = <2>;
 				interrupt-controller;
 				#interrupt-cells = <2>;
 				interrupts = <87>, <88>, <89>, <90>;
+				clocks = <&coreclk 0>;
 			};
 
 			gpio2: gpio@18180 {
--- a/arch/arm/boot/dts/armada-xp-mv78230.dtsi
+++ b/arch/arm/boot/dts/armada-xp-mv78230.dtsi
@@ -203,24 +203,30 @@
 		internal-regs {
 			gpio0: gpio@18100 {
 				compatible = "marvell,orion-gpio";
-				reg = <0x18100 0x40>;
+				reg = <0x18100 0x40>, <0x181c0 0x08>;
+				reg-names = "gpio", "pwm";
 				ngpios = <32>;
 				gpio-controller;
 				#gpio-cells = <2>;
+				#pwm-cells = <2>;
 				interrupt-controller;
 				#interrupt-cells = <2>;
 				interrupts = <82>, <83>, <84>, <85>;
+				clocks = <&coreclk 0>;
 			};
 
 			gpio1: gpio@18140 {
 				compatible = "marvell,orion-gpio";
-				reg = <0x18140 0x40>;
+				reg = <0x18140 0x40>, <0x181c8 0x08>;
+				reg-names = "gpio", "pwm";
 				ngpios = <17>;
 				gpio-controller;
 				#gpio-cells = <2>;
+				#pwm-cells = <2>;
 				interrupt-controller;
 				#interrupt-cells = <2>;
 				interrupts = <87>, <88>, <89>;
+				clocks = <&coreclk 0>;
 			};
 		};
 	};
--- a/arch/arm/boot/dts/armada-xp-mv78260.dtsi
+++ b/arch/arm/boot/dts/armada-xp-mv78260.dtsi
@@ -287,24 +287,28 @@
 		internal-regs {
 			gpio0: gpio@18100 {
 				compatible = "marvell,orion-gpio";
-				reg = <0x18100 0x40>;
+				reg = <0x18100 0x40>, <0x181c0 0x08>;
+				reg-names = "gpio", "pwm";
 				ngpios = <32>;
 				gpio-controller;
 				#gpio-cells = <2>;
+				#pwm-cells = <2>;
 				interrupt-controller;
 				#interrupt-cells = <2>;
 				interrupts = <82>, <83>, <84>, <85>;
+				clocks = <&coreclk 0>;
 			};
 
 			gpio1: gpio@18140 {
 				compatible = "marvell,orion-gpio";
-				reg = <0x18140 0x40>;
+				reg = <0x18140 0x40>, <0x181c8 0x08>;
 				ngpios = <32>;
 				gpio-controller;
 				#gpio-cells = <2>;
 				interrupt-controller;
 				#interrupt-cells = <2>;
 				interrupts = <87>, <88>, <89>, <90>;
+				clocks = <&coreclk 0>;
 			};
 
 			gpio2: gpio@18180 {
--- a/arch/arm/boot/dts/armada-xp-mv78460.dtsi
+++ b/arch/arm/boot/dts/armada-xp-mv78460.dtsi
@@ -325,24 +325,30 @@
 		internal-regs {
 			gpio0: gpio@18100 {
 				compatible = "marvell,orion-gpio";
-				reg = <0x18100 0x40>;
+				reg = <0x18100 0x40>, <0x181c0 0x08>;
+				reg-names = "gpio", "pwm";
 				ngpios = <32>;
 				gpio-controller;
 				#gpio-cells = <2>;
+				#pwm-cells = <2>;
 				interrupt-controller;
 				#interrupt-cells = <2>;
 				interrupts = <82>, <83>, <84>, <85>;
+				clocks = <&coreclk 0>;
 			};
 
 			gpio1: gpio@18140 {
 				compatible = "marvell,orion-gpio";
-				reg = <0x18140 0x40>;
+				reg = <0x18140 0x40>, <0x181c8 0x08>;
+				reg-names = "gpio", "pwm";
 				ngpios = <32>;
 				gpio-controller;
 				#gpio-cells = <2>;
+				#pwm-cells = <2>;
 				interrupt-controller;
 				#interrupt-cells = <2>;
 				interrupts = <87>, <88>, <89>, <90>;
+				clocks = <&coreclk 0>;
 			};
 
 			gpio2: gpio@18180 {
Now that the gpio driver also supports PWM operation, enable
the PWM framework in mvebu_v7_defconfig.

Signed-off-by: Andrew Lunn <andrew@lunn.ch>
---
 arch/arm/configs/mvebu_v7_defconfig | 1 +
 1 file changed, 1 insertion(+)

--- a/arch/arm/configs/mvebu_v7_defconfig
+++ b/arch/arm/configs/mvebu_v7_defconfig
@@ -118,6 +118,7 @@ CONFIG_DMADEVICES=y
 CONFIG_MV_XOR=y
 # CONFIG_IOMMU_SUPPORT is not set
 CONFIG_MEMORY=y
+CONFIG_PWM=y
 CONFIG_EXT4_FS=y
 CONFIG_ISO9660_FS=y
 CONFIG_JOLIET=y
The mvebu gpio driver can also perform PWM on some pins. Us the
pwm-fan driver to control the fan of the WRT1900AC, giving us fine
grain control over its speed and hence noise.

Signed-off-by: Andrew Lunn <andrew@lunn.ch>
---
 arch/arm/boot/dts/armada-xp-wrt1900ac.dts | 8 +++-----
 1 file changed, 3 insertions(+), 5 deletions(-)

--- a/arch/arm/boot/dts/armada-xp-linksys-mamba.dts
+++ b/arch/arm/boot/dts/armada-xp-linksys-mamba.dts
@@ -407,13 +407,11 @@
 		};
 	};
 
-	gpio_fan {
+	pwm_fan {
 		/* SUNON HA4010V4-0000-C99 */
-		compatible = "gpio-fan";
-		gpios = <&gpio0 24 0>;
 
-		gpio-fan,speed-map = <0    0
-				      4500 1>;
+		compatible = "pwm-fan";
+		pwms = <&gpio0 24 4000 0>;
 	};
 
 	mvsw61xx {

Signed-off-by: valcher
---
 arch/arm/boot/dts/armada-38x.dtsi | 10 ++++++++--
 1 file changed, 8 insertions(+), 2 deletions(-)

--- a/arch/arm/boot/dts/armada-38x.dtsi 2017-03-18 14:19:00.000000000 +0300
+++ b/arch/arm/boot/dts/armada-38x.dtsi 2017-03-20 01:29:32.000000000 +0300
@@ -313,28 +313,34 @@
			gpio0: gpio@18100 {
				compatible = "marvell,orion-gpio";
-				reg = <0x18100 0x40>;
+				reg = <0x18100 0x40>, <0x181c0 0x08>;
+				reg-names = "gpio", "pwm";
				ngpios = <32>;
				gpio-controller;
				#gpio-cells = <2>;
+				#pwm-cells = <2>;
				interrupt-controller;
				#interrupt-cells = <2>;
+				clocks = <&coreclk 0>;
				interrupts = <GIC_SPI 53 IRQ_TYPE_LEVEL_HIGH>,
					     <GIC_SPI 54 IRQ_TYPE_LEVEL_HIGH>,
					     <GIC_SPI 55 IRQ_TYPE_LEVEL_HIGH>,
					     <GIC_SPI 56 IRQ_TYPE_LEVEL_HIGH>;
			};

			gpio1: gpio@18140 {
				compatible = "marvell,orion-gpio";
-				reg = <0x18140 0x40>;
+				reg = <0x18140 0x40>, <0x181c8 0x08>;
+				reg-names = "gpio", "pwm";
				ngpios = <28>;
				gpio-controller;
				#gpio-cells = <2>;
+				#pwm-cells = <2>;
				interrupt-controller;
				#interrupt-cells = <2>;
+				clocks = <&coreclk 0>;
				interrupts = <GIC_SPI 58 IRQ_TYPE_LEVEL_HIGH>,
					     <GIC_SPI 59 IRQ_TYPE_LEVEL_HIGH>,
					     <GIC_SPI 60 IRQ_TYPE_LEVEL_HIGH>,
					     <GIC_SPI 61 IRQ_TYPE_LEVEL_HIGH>;
			};

