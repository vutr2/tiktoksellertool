import unittest
from validate_release import public_https, validate


class ReleaseConfigurationTests(unittest.TestCase):
    def test_rejects_local_or_placeholder_urls(self):
        for value in ["", "http://api.company.com", "https://localhost", "https://LOCALHOST.",
                      "https://127.1", "https://127.0.0.2", "https://2130706433",
                      "https://[::1]", "https://[::ffff:127.0.0.1]", "https://0.0.0.0",
                      "https://192.168.1.10", "https://api.example.com", "https://api.test",
                      "https://user:password@api.company.com", "https://api.company.com/#fragment"]:
            with self.subTest(value=value):
                self.assertFalse(public_https(value))

    def test_accepts_public_https(self):
        self.assertTrue(public_https("https://api.company.com/v1"))

    def test_missing_submission_urls_block_release(self):
        self.assertEqual(len(validate({"CONFIGURATION": "Release"})), 4)
        self.assertEqual(validate({"CONFIGURATION": "Debug"}), [])


if __name__ == "__main__":
    unittest.main()
