"""Exercise the installed standalone helper and zsh, with disposable databases."""
import concurrent.futures
import os
import re
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SHELL_HOME = Path(os.environ.get("MY_SHELL_HOME", "~/.emacs/shell")).expanduser()


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, MY_SHELL_DB=str(self.root / "history.sqlite3"),
                        MY_SHELL_CONTEXT="copy:one", MY_SHELL_NAME="shell",
                        MY_SHELL_PYTHON=sys.executable, MY_SHELL_HOME=str(SHELL_HOME),
                        ZDOTDIR=str(SHELL_HOME / "zsh"), TERM="xterm-256color")
        self.env.pop("INSIDE_EMACS", None)

    def call(self, action, command="", **env):
        return subprocess.run([sys.executable, str(SHELL_HOME / "history.py"), action],
                              input=command.encode(), capture_output=True,
                              env=dict(self.env, **env), timeout=10)

    def add(self, command, **env):
        result = self.call("add", command, **env)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def entries(self, **env):
        result = self.call("load", **env)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout.decode().split("\0")[:-1]

    def shell(self, commands, **env):
        return subprocess.run(["/bin/zsh", "-d", "-i"], input=commands,
                              capture_output=True, text=True, cwd=self.root,
                              env=dict(self.env, **env), timeout=15)

    def test_multiline_unicode_and_quotes_round_trip_without_execution(self):
        commands = ["printf '%s\\n' 'Привет'", 'echo "a\\b"\n\necho two\n',
                    f"touch {self.root / 'MUST-NOT-EXIST'}", "echo $(date); ' OR 1=1 --"]
        for command in commands:
            self.add(command)
        self.assertEqual(self.entries(), commands)
        result = self.shell(" print -r -- ${(j:|:)${(v)history}}\n exit\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Привет", result.stdout)
        self.assertFalse((self.root / "MUST-NOT-EXIST").exists())
        self.assertEqual(self.entries(), commands)

    def test_context_and_named_terminal_isolation(self):
        self.add("one")
        self.add("server", MY_SHELL_NAME="server")
        self.add("original", MY_SHELL_CONTEXT="original:project")
        self.assertEqual(self.entries(), ["one"])
        self.assertEqual(self.entries(MY_SHELL_NAME="server"), ["server"])
        self.assertEqual(self.entries(MY_SHELL_CONTEXT="original:project"), ["original"])

    def test_parallel_commits_are_not_lost(self):
        self.entries()  # create schema before simulating simultaneous sessions
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda n: self.add(f"command {n}"), range(24)))
        self.assertEqual(set(self.entries()), {f"command {n}" for n in range(24)})

    def test_delete_removes_all_terminals_and_rejects_late_writes(self):
        self.add("one")
        self.add("server", MY_SHELL_NAME="server")
        self.add("keep", MY_SHELL_CONTEXT="original:project")
        result = self.call("delete-worktree")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.call("add", "late").returncode, 0)
        self.assertNotEqual(self.call("load").returncode, 0)
        self.assertEqual(self.entries(MY_SHELL_CONTEXT="original:project"), ["keep"])
        self.assertNotEqual(self.call("delete-worktree", MY_SHELL_CONTEXT="original:project").returncode, 0)
        import sqlite3
        with sqlite3.connect(self.env["MY_SHELL_DB"]) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM history WHERE context='copy:one'").fetchone()[0], 0)

    def test_shell_records_commands_but_not_leading_space_and_reloads(self):
        first = self.shell("echo saved\n echo private\n exit\n")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.entries(), ["echo saved"])
        again = self.shell(" fc -ln 1\n exit\n")
        self.assertIn("echo saved", again.stdout)
        self.assertEqual(self.entries(), ["echo saved"])
        self.assertFalse((self.root / ".zsh_history").exists())

    def test_missing_sqlite_reports_interpreter_and_keeps_memory_history(self):
        (self.root / "sqlite3.py").write_text("raise ImportError('no _sqlite3 available')\n")
        result = self.call("load", PYTHONPATH=str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(sys.executable, result.stderr.decode())
        self.assertNotIn("Traceback", result.stderr.decode())
        shell = self.shell('echo memory\n fc -ln 1\n print -P -- "$PROMPT"\n exit\n',
                           PYTHONPATH=str(self.root))
        self.assertEqual(shell.returncode, 0, shell.stderr)
        self.assertIn("НЕ сохраняется", shell.stderr)
        self.assertIn("[history: off]", shell.stdout)
        self.assertIn("echo memory", shell.stdout)
        self.assertFalse(Path(self.env["MY_SHELL_DB"]).exists())

    def test_unavailable_temp_directory_visibly_disables_history(self):
        result = self.shell('echo memory\n print -P -- "$PROMPT"\n exit\n',
                            TMPDIR=str(self.root / "missing"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("НЕ сохраняется", result.stderr)
        self.assertIn("[history: off]", result.stdout)

    def test_prompt_is_relative_to_project_and_escapes_directory_names(self):
        directory = self.root / 'api %B $(touch OWNED)'
        directory.mkdir()
        result = self.shell(
            " print -P -- \"PROMPT:$PROMPT\"\n"
            f" cd -- {shlex.quote(str(directory))}\n"
            " print -P -- \"PROMPT:$PROMPT\"\n exit\n",
            MY_SHELL_PROJECT_ROOT=str(self.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        plain = re.sub(r"\x1b\[[0-9; ]*[A-Za-z]", "", result.stdout)
        self.assertIn("PROMPT:[ . ] ", plain)
        self.assertIn("PROMPT:[ api %B $(touch OWNED) ] ", plain)
        self.assertIn("\x1b[34m", result.stdout)
        self.assertIn("\x1b[1m", result.stdout)
        self.assertFalse((directory / "OWNED").exists())

    def test_prompt_outside_project_does_not_mislabel_neighbor_as_relative(self):
        project = self.root / "project"
        neighbor = self.root / "project-other"
        project.mkdir()
        neighbor.mkdir()
        result = self.shell(f" cd -- {shlex.quote(str(neighbor))}\n print -P -- \"PROMPT:$PROMPT\"\n exit\n",
                            MY_SHELL_PROJECT_ROOT=str(project))
        plain = re.sub(r"\x1b\[[0-9; ]*[A-Za-z]", "", result.stdout)
        self.assertIn(f"PROMPT:[ {neighbor.resolve()} ] ", plain)


if __name__ == "__main__":
    unittest.main(verbosity=2)
