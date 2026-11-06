// SPDX-License-Identifier: GPL-2.0
/*
 * dwc2_wakeup - USB remote wakeup for a dwc2 gadget (Pi 4 USB-C port).
 *
 * A real keyboard wakes a sleeping PC by driving resume signaling on the
 * suspended bus. dwc2's usb_gadget_ops has no .wakeup, so usb_gadget_wakeup()
 * and the UDC's `srp` sysfs file silently do nothing. Poking DCTL.RmtWkUpSig
 * from /dev/mem does wake the host, but leaves the driver in L2: the hardware
 * raises no WkUpInt for a resume the device started, so dwc2 keeps refusing
 * requests (-EAGAIN) and the host's first control transfer after resume
 * fails ("dwc2_hsotg_send_reply: cannot queue req").
 *
 * This module does what dwc2_gadget_exit_clock_gating(hsotg, 1) would (that
 * function exists but nothing calls it with rem_wakeup=1 in device mode, and
 * it never ends the signaling): under the driver's lock, ungate the PHY clock,
 * start resume signaling, call the gadget's resume and move to L0. It ends
 * the signaling 5 ms later (USB 2.0 says 1-15 ms). If the host doesn't resume
 * the bus, dwc2's own suspend interrupt puts it back to sleep; if that
 * doesn't come either, this module does the same itself.
 *
 *   echo 1 > /sys/module/dwc2_wakeup/parameters/wake   # EALREADY if awake
 *   cat /sys/module/dwc2_wakeup/parameters/state
 *
 * Needs dwc2's private core.h/hw.h for struct dwc2_hsotg; build.sh fetches
 * them for the running kernel, and the module checks the layout at runtime
 * (hsotg->dev, gadget.name, the core's ID register) before touching anything.
 */
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include "core.h"

static char *udc = "fe980000.usb";
module_param(udc, charp, 0444);
MODULE_PARM_DESC(udc, "platform device name of the dwc2 controller");

static DEFINE_MUTEX(wake_lock);

/* Returns the controller with a device reference held, or an ERR_PTR. */
static struct dwc2_hsotg *get_hsotg(struct device **devp)
{
	struct device *dev;
	struct dwc2_hsotg *hs;

	dev = bus_find_device_by_name(&platform_bus_type, NULL, udc);
	if (!dev)
		return ERR_PTR(-ENODEV);
	hs = dev_get_drvdata(dev);
	if (!hs || hs->dev != dev || !hs->regs || !hs->gadget.name ||
	    strcmp(hs->gadget.name, dev_name(dev)) ||
	    (dwc2_readl(hs, GSNPSID) & GSNPSID_ID_MASK) != DWC2_OTG_ID) {
		dev_err(dev, "dwc2_wakeup: struct dwc2_hsotg doesn't match this kernel; rebuild the module\n");
		put_device(dev);
		return ERR_PTR(-ENODEV);
	}
	*devp = dev;
	return hs;
}

static u32 frame_number(struct dwc2_hsotg *hs)
{
	return (dwc2_readl(hs, DSTS) & DSTS_SOFFN_MASK) >> DSTS_SOFFN_SHIFT;
}

static int do_wake(struct dwc2_hsotg *hs)
{
	unsigned long flags;
	u32 dsts, fn;
	int i;

	spin_lock_irqsave(&hs->lock, flags);
	dsts = dwc2_readl(hs, DSTS);
	if (!dwc2_is_device_mode(hs) || !hs->connected) {
		spin_unlock_irqrestore(&hs->lock, flags);
		return -ENOTCONN;
	}
	if (!(dsts & DSTS_SUSPSTS) || hs->lx_state != DWC2_L2) {
		spin_unlock_irqrestore(&hs->lock, flags);
		return -EALREADY;
	}
	if (hs->params.power_down != DWC2_POWER_DOWN_PARAM_NONE) {
		/* Partial power down / hibernation need their own exit paths. */
		spin_unlock_irqrestore(&hs->lock, flags);
		return -EOPNOTSUPP;
	}
	if (!hs->remote_wakeup_allowed)
		dev_info(hs->dev, "dwc2_wakeup: host hasn't enabled remote wakeup; signaling anyway\n");

	/* dwc2_gadget_exit_clock_gating(hs, 1), inlined. */
	if (hs->bus_suspended && !hs->params.no_clock_gating) {
		dwc2_writel(hs, dwc2_readl(hs, PCGCTL) & ~PCGCTL_GATEHCLK, PCGCTL);
		udelay(5);
		dwc2_writel(hs, dwc2_readl(hs, PCGCTL) & ~PCGCTL_STOPPCLK, PCGCTL);
		udelay(5);
	}
	fn = frame_number(hs);
	dwc2_writel(hs, dwc2_readl(hs, DCTL) | DCTL_RMTWKUPSIG, DCTL);
	call_gadget(hs, resume);
	hs->lx_state = DWC2_L0;
	hs->bus_suspended = false;
	spin_unlock_irqrestore(&hs->lock, flags);

	usleep_range(5000, 6000);

	spin_lock_irqsave(&hs->lock, flags);
	dwc2_writel(hs, dwc2_readl(hs, DCTL) & ~DCTL_RMTWKUPSIG, DCTL);
	spin_unlock_irqrestore(&hs->lock, flags);

	/* The host drives resume for 20 ms, then SOFs start. */
	for (i = 0; i < 25; i++) {
		msleep(20);
		if (frame_number(hs) != fn) {
			dev_info(hs->dev, "dwc2_wakeup: host resumed the bus\n");
			return 0;
		}
	}

	/*
	 * No SOFs. Normally dwc2's suspend interrupt has already put the
	 * driver back in L2; if not, do what that handler does.
	 */
	spin_lock_irqsave(&hs->lock, flags);
	if (hs->lx_state == DWC2_L0 && (dwc2_readl(hs, DSTS) & DSTS_SUSPSTS)) {
		if (!hs->params.no_clock_gating) {
			dwc2_writel(hs, dwc2_readl(hs, PCGCTL) | PCGCTL_STOPPCLK, PCGCTL);
			udelay(5);
			dwc2_writel(hs, dwc2_readl(hs, PCGCTL) | PCGCTL_GATEHCLK, PCGCTL);
			udelay(5);
			hs->bus_suspended = true;
		}
		hs->lx_state = DWC2_L2;
		call_gadget(hs, suspend);
	}
	spin_unlock_irqrestore(&hs->lock, flags);
	dev_info(hs->dev, "dwc2_wakeup: host didn't resume the bus\n");
	return -ETIMEDOUT;
}

static int wake_set(const char *val, const struct kernel_param *kp)
{
	struct dwc2_hsotg *hs;
	struct device *dev;
	bool on;
	int ret;

	ret = kstrtobool(val, &on);
	if (ret || !on)
		return ret;
	hs = get_hsotg(&dev);
	if (IS_ERR(hs))
		return PTR_ERR(hs);
	mutex_lock(&wake_lock);
	ret = do_wake(hs);
	mutex_unlock(&wake_lock);
	put_device(dev);
	return ret;
}

static int state_get(char *buf, const struct kernel_param *kp)
{
	struct dwc2_hsotg *hs;
	struct device *dev;
	unsigned long flags;
	int n;

	hs = get_hsotg(&dev);
	if (IS_ERR(hs))
		return PTR_ERR(hs);
	spin_lock_irqsave(&hs->lock, flags);
	n = scnprintf(buf, PAGE_SIZE,
		      "suspended=%d lx_state=L%d connected=%d remote_wakeup_allowed=%d\n",
		      !!(dwc2_readl(hs, DSTS) & DSTS_SUSPSTS), hs->lx_state,
		      hs->connected, hs->remote_wakeup_allowed);
	spin_unlock_irqrestore(&hs->lock, flags);
	put_device(dev);
	return n;
}

static const struct kernel_param_ops wake_ops = { .set = wake_set };
static const struct kernel_param_ops state_ops = { .get = state_get };
module_param_cb(wake, &wake_ops, NULL, 0200);
MODULE_PARM_DESC(wake, "write 1 to send USB remote wakeup to the host");
module_param_cb(state, &state_ops, NULL, 0444);
MODULE_PARM_DESC(state, "bus and driver suspend state");

static int __init dwc2_wakeup_init(void)
{
	struct dwc2_hsotg *hs;
	struct device *dev;

	/* Fail the load if the layout doesn't match, rather than at first use. */
	hs = get_hsotg(&dev);
	if (IS_ERR(hs))
		return PTR_ERR(hs);
	put_device(dev);
	return 0;
}
module_init(dwc2_wakeup_init);

static void __exit dwc2_wakeup_exit(void) {}
module_exit(dwc2_wakeup_exit);

MODULE_DESCRIPTION("USB remote wakeup for dwc2 gadgets");
MODULE_LICENSE("GPL");
