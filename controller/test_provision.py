from pathlib import Path
import tempfile
import unittest
import prepare_sd
class ProvisionTests(unittest.TestCase):
    def test_failure_rolls_back_and_retry_succeeds(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); boot = root/'boot'; boot.mkdir()
            (boot/'config.txt').write_text('')
            original = 'console=serial0,115200 console=tty1 rootwait systemd.run=/boot/firmware/firstrun.sh\n'
            (boot/'cmdline.txt').write_text(original)
            receipt = root/'receipt.json'
            def fail(): raise OSError('Injected full disk')
            with self.assertRaises(OSError): prepare_sd.prepare(boot, receipt_path=receipt, before_commit=fail)
            self.assertEqual((boot/'cmdline.txt').read_text(),original)
            self.assertEqual((boot/'config.txt').read_text(),'')
            self.assertFalse((boot/'vgf-controller').exists())
            self.assertFalse(receipt.exists())
            prepare_sd.prepare(boot, receipt_path=receipt)
            self.assertTrue(receipt.exists())
            config = (boot/'config.txt').read_text()
            self.assertIn('[all]\n# Video Game Filter USB controller\ndtoverlay=dwc2,dr_mode=peripheral', config)
            self.assertIn('enable_uart=1\ncore_freq=250', config)
            self.assertNotIn('console=serial0,', (boot/'cmdline.txt').read_text())
            self.assertEqual((boot/'vgf-firstboot.sh').read_bytes(), (Path(prepare_sd.__file__).parent/'firstboot.sh').read_bytes())
            self.assertEqual((boot/'vgf-previous-run.txt').read_text(), '/boot/firmware/firstrun.sh')
            self.assertEqual((boot/'cmdline.txt.vgf-serial-backup').read_text(), 'console=serial0,115200 console=tty1 rootwait\n')
