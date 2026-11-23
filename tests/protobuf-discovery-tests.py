"""Import discovery must work without build scripts or repository writes."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "protobuf_lsp", Path(__file__).resolve().parents[1] / "tools/protobuf-lsp.py")
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def write(self, name, text=""):
        file = self.root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        return file

    def test_transitive_imports_and_siblings_without_generate(self):
        entry = self.write("service/api/a.proto", 'import "acme/types.proto";')
        self.write("service/api/b.proto", 'import "common/options.proto";')
        self.write("vendor/private/acme/types.proto", 'import public "common/options.proto";')
        self.write("vendor/common/common/options.proto", 'import weak "acme/types.proto";')
        before = sorted(self.root.rglob("*"))
        config = discovery.configuration(self.root, entry)
        self.assertEqual(config, {"version": "v2", "modules": [
            {"path": "service/api"}, {"path": "vendor/common"}, {"path": "vendor/private"}]})
        self.assertEqual(sorted(self.root.rglob("*")), before)

    def test_comments_and_string_literals_are_not_imports(self):
        entry = self.write("api/a.proto", '''
// import "missing/a.proto";
/* import "missing/b.proto"; */
option description = "import \\"missing/c.proto\\";";
import /* comment */ public 'real/type.proto';
''')
        self.write("deps/real/type.proto")
        self.assertEqual(discovery.configuration(self.root, entry)["modules"],
                         [{"path": "api"}, {"path": "deps"}])

    def test_prefers_dependency_near_importing_library(self):
        entry = self.write("api/a.proto", 'import "acme/types.proto";')
        self.write("deps/acme/acme/types.proto", 'import "google/api/annotations.proto";')
        self.write("deps/acme/third_party/google/api/annotations.proto", "near")
        self.write("deps/other/google/api/annotations.proto", "other version")
        self.assertEqual(discovery.configuration(self.root, entry)["modules"], [
            {"path": "api"},
            {"path": "deps/acme", "excludes": ["deps/acme/third_party"]},
            {"path": "deps/acme/third_party"}])

    def test_ambiguous_different_versions_are_not_chosen_arbitrarily(self):
        entry = self.write("api/a.proto", 'import "acme/types.proto";')
        self.write("deps/one/acme/types.proto", "version one")
        self.write("deps/two/acme/types.proto", "version two")
        with self.assertRaisesRegex(ValueError, "Ambiguous import.*acme/types.proto"):
            discovery.configuration(self.root, entry)

    def test_identical_copies_are_equivalent(self):
        entry = self.write("api/a.proto", 'import "acme/types.proto";')
        self.write("deps/one/acme/types.proto", "same")
        self.write("deps/two/acme/types.proto", "same")
        self.assertEqual(discovery.configuration(self.root, entry)["modules"],
                         [{"path": "api"}, {"path": "deps/one"}])

    def test_local_import_beats_same_named_file_elsewhere(self):
        entry = self.write("api/a.proto", 'import "types.proto";')
        self.write("api/types.proto", "local")
        self.write("unrelated/types.proto", "other")
        self.assertEqual(discovery.configuration(self.root, entry)["modules"], [{"path": "api"}])

    def test_identical_files_with_context_dependent_imports_remain_ambiguous(self):
        entry = self.write("api/a.proto", 'import "acme/types.proto";')
        self.write("deps/one/acme/types.proto", 'import "common.proto";')
        self.write("deps/two/acme/types.proto", 'import "common.proto";')
        self.write("deps/one/acme/common.proto", "one version")
        self.write("deps/two/acme/common.proto", "another version")
        with self.assertRaisesRegex(ValueError, "Ambiguous import"):
            discovery.configuration(self.root, entry)

    def test_well_known_types_do_not_select_bundled_toolchain(self):
        entry = self.write("api/a.proto", 'import "google/protobuf/timestamp.proto";')
        self.write("tools/include/google/protobuf/timestamp.proto")
        self.assertEqual(discovery.configuration(self.root, entry)["modules"], [{"path": "api"}])

    def test_symlink_outside_project_is_not_an_include_root(self):
        entry = self.write("api/a.proto", 'import "types.proto";')
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / "types.proto"
            target.write_text("")
            (entry.parent / "types.proto").symlink_to(target)
            self.assertEqual(discovery.configuration(self.root, entry)["modules"], [{"path": "api"}])


if __name__ == "__main__":
    unittest.main()
