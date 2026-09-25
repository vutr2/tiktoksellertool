import json
import pathlib
import tempfile
import unittest

import check_localization as checker


class UntranslatedTests(unittest.TestCase):
    def catalog(self, strings):
        return strings

    def test_a_new_english_string_is_reported(self):
        # The failure this exists to catch: someone adds Text("New button")
        # and a Vietnamese seller reads one English word mid-screen.
        missing = checker.untranslated({"New button": "ProductsView.swift"}, {}, "vi")
        self.assertEqual(len(missing), 1)
        self.assertIn("New button", missing[0])
        self.assertIn("ProductsView.swift", missing[0])

    def test_a_translated_string_passes(self):
        strings = {"Settings": {"localizations": {"vi": {"stringUnit": {"state": "translated", "value": "Cài đặt"}}}}}
        self.assertEqual(checker.untranslated({"Settings": "a.swift"}, strings, "vi"), [])

    def test_an_empty_translation_is_not_a_translation(self):
        strings = {"Settings": {"localizations": {"vi": {"stringUnit": {"state": "translated", "value": ""}}}}}
        self.assertEqual(len(checker.untranslated({"Settings": "a.swift"}, strings, "vi")), 1)

    def test_a_needs_review_translation_is_reported(self):
        strings = {"Settings": {"localizations": {"vi": {"stringUnit": {"state": "needs_review", "value": "Cài đặt"}}}}}
        self.assertEqual(len(checker.untranslated({"Settings": "a.swift"}, strings, "vi")), 1)

    def test_a_deliberate_exemption_is_allowed(self):
        # No localizations at all means the key is meant to read the same in
        # both languages — a brand name, a separator, a pure format string.
        strings = {"Listing Force": {"localizations": {}}}
        self.assertEqual(checker.untranslated({"Listing Force": "a.swift"}, strings, "vi"), [])


class BuildKeyTests(unittest.TestCase):
    def test_keys_are_read_from_every_stringsdata_file(self):
        with tempfile.TemporaryDirectory() as directory:
            objects = pathlib.Path(directory)
            (objects / "A.stringsdata").write_text(json.dumps({
                "source": "/x/AuthView.swift",
                "tables": {"Localizable": [{"key": "Email"}, {"key": "Send"}]},
            }))
            (objects / "B.stringsdata").write_text(json.dumps({
                "source": "/x/SettingsView.swift",
                "tables": {"Localizable": [{"key": "Settings"}]},
            }))
            # Not every .stringsdata is a Swift table; a broken one must not
            # abort the whole check.
            (objects / "C.stringsdata").write_text("not json")

            keys = checker.keys_from_build(objects)

        self.assertEqual(keys, {"Email": "AuthView.swift", "Send": "AuthView.swift",
                                "Settings": "SettingsView.swift"})


if __name__ == "__main__":
    unittest.main()
