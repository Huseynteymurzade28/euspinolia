"""Phase 3 tests: reading CSV into a DataFrame from Python.

Run from the repo root:
    zig build && python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import ctypes
import gc
import sys
import tempfile
import unittest
from pathlib import Path

# Allow importing the package without installing it.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import euspinolia  # noqa: E402

SAMPLE = 'name,age,score\nada,36,91.5\ngrace,45,88.0\n"Doe, John",29,73.25\n'


class TestReadCsv(unittest.TestCase):
    def test_parses_text(self):
        df = euspinolia.parse_csv(SAMPLE)
        self.assertEqual(df.shape, (3, 3))
        self.assertEqual(len(df), 3)
        self.assertEqual(df.columns, ("name", "age", "score"))

    def test_accepts_bytes(self):
        df = euspinolia.parse_csv(b"a,b\n1,2\n")
        self.assertEqual(df.shape, (1, 2))

    def test_reads_a_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "people.csv"
            path.write_text(SAMPLE, encoding="utf-8")

            df = euspinolia.read_csv(path)
            self.assertEqual(df.shape, (3, 3))
            self.assertEqual(df["name"][0], "ada")

    def test_accepts_a_path_string(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "people.csv"
            path.write_text("a\n1\n", encoding="utf-8")

            df = euspinolia.read_csv(str(path))
            self.assertEqual(len(df), 1)

    def test_header_only_file_has_no_rows(self):
        df = euspinolia.parse_csv("a,b\n")
        self.assertEqual(df.shape, (0, 2))
        self.assertEqual(df["a"].to_list(), [])
        self.assertEqual(df.head(), [])


class TestTypeInference(unittest.TestCase):
    def test_infers_a_type_per_column(self):
        df = euspinolia.parse_csv(SAMPLE)
        self.assertEqual(
            df.dtypes,
            (
                euspinolia.ColumnType.STRING,
                euspinolia.ColumnType.INT,
                euspinolia.ColumnType.FLOAT,
            ),
        )

    def test_python_types_match_the_column_type(self):
        df = euspinolia.parse_csv(SAMPLE)
        self.assertIsInstance(df["age"][0], int)
        self.assertIsInstance(df["score"][0], float)
        self.assertIsInstance(df["name"][0], str)

    def test_dtype_prints_readably(self):
        df = euspinolia.parse_csv("n\n1\n")
        self.assertEqual(str(df["n"].dtype), "int")


class TestColumnAccess(unittest.TestCase):
    def setUp(self):
        self.df = euspinolia.parse_csv(SAMPLE)

    def test_by_name(self):
        self.assertEqual(self.df["age"].to_list(), [36, 45, 29])

    def test_by_position(self):
        self.assertEqual(self.df[1].name, "age")
        self.assertEqual(self.df[-1].name, "score")

    def test_missing_column_names_the_alternatives(self):
        with self.assertRaises(KeyError) as caught:
            self.df["nope"]
        self.assertIn("age", str(caught.exception))

    def test_column_index_out_of_range(self):
        with self.assertRaises(IndexError):
            self.df[9]

    def test_negative_and_sliced_rows(self):
        self.assertEqual(self.df["age"][-1], 29)
        self.assertEqual(self.df["age"][1:], [45, 29])

    def test_row_out_of_range(self):
        with self.assertRaises(IndexError):
            self.df["age"][3]

    def test_iterating_a_column(self):
        self.assertEqual(list(self.df["name"]), ["ada", "grace", "Doe, John"])

    def test_iterating_the_frame_yields_column_names(self):
        self.assertEqual(list(self.df), ["name", "age", "score"])
        self.assertIn("score", self.df)

    def test_rows_and_head(self):
        self.assertEqual(self.df.row(0), ("ada", 36, 91.5))
        self.assertEqual(self.df.head(2), [("ada", 36, 91.5), ("grace", 45, 88.0)])
        self.assertEqual(len(self.df.head(99)), 3)

    def test_quoted_field_keeps_its_delimiter(self):
        self.assertEqual(self.df["name"][2], "Doe, John")

    def test_empty_strings_survive(self):
        df = euspinolia.parse_csv("s,n\nada,1\n,2\n")
        self.assertEqual(df["s"].to_list(), ["ada", ""])

    def test_non_ascii_text(self):
        df = euspinolia.parse_csv("city\nİstanbul\nİzmir\n")
        self.assertEqual(df["city"].to_list(), ["İstanbul", "İzmir"])


class TestZeroCopy(unittest.TestCase):
    def test_numeric_columns_are_views_not_copies(self):
        df = euspinolia.parse_csv("n\n1\n2\n")
        column = df["n"]

        # The ctypes array must sit on the address Zig handed out, meaning
        # reads go straight into the frame's arena.
        from euspinolia._ffi import lib

        self.assertEqual(ctypes.addressof(column._values), lib.eus_frame_ints(df._handle, 0))

    def test_two_reads_share_the_same_buffer(self):
        df = euspinolia.parse_csv("n\n1\n")
        self.assertEqual(ctypes.addressof(df["n"]._values), ctypes.addressof(df["n"]._values))


class TestMemoryOwnership(unittest.TestCase):
    def test_close_is_idempotent(self):
        df = euspinolia.parse_csv("a\n1\n")
        df.close()
        df.close()

    def test_reading_a_closed_frame_raises(self):
        df = euspinolia.parse_csv("a\n1\n")
        df.close()
        with self.assertRaises(ValueError):
            df["a"]

    def test_a_column_of_a_closed_frame_raises(self):
        df = euspinolia.parse_csv("a\n1\n")
        column = df["a"]
        df.close()
        with self.assertRaises(ValueError):
            column[0]

    def test_context_manager_closes(self):
        with euspinolia.parse_csv("a\n1\n") as df:
            self.assertEqual(df["a"][0], 1)
        with self.assertRaises(ValueError):
            df["a"]

    def test_a_column_keeps_its_frame_alive(self):
        # The frame has no other reference left; the column must still be
        # readable, or we would be reading freed Zig memory.
        column = euspinolia.parse_csv("s\nada\n")["s"]
        gc.collect()
        self.assertEqual(column[0], "ada")

    def test_repr_of_a_closed_frame(self):
        df = euspinolia.parse_csv("a\n1\n")
        df.close()
        self.assertIn("closed", repr(df))


class TestErrors(unittest.TestCase):
    def test_missing_file(self):
        with self.assertRaises(FileNotFoundError) as caught:
            euspinolia.read_csv("no-such-file-here.csv")
        self.assertIn("no-such-file-here.csv", str(caught.exception))

    def test_directory_instead_of_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(OSError):
                euspinolia.read_csv(tmp)

    def test_empty_input_has_no_header(self):
        with self.assertRaises(euspinolia.ParseError):
            euspinolia.parse_csv("")

    def test_ragged_row(self):
        with self.assertRaises(euspinolia.ParseError) as caught:
            euspinolia.parse_csv("a,b\n1,2,3\n")
        self.assertIn("field count", str(caught.exception))

    def test_unterminated_quote(self):
        with self.assertRaises(euspinolia.ParseError):
            euspinolia.parse_csv('a\n"oops\n')

    def test_parse_error_is_a_value_error(self):
        self.assertTrue(issubclass(euspinolia.ParseError, ValueError))


class TestRepr(unittest.TestCase):
    def test_shows_the_shape(self):
        self.assertIn("[3 rows x 3 columns]", repr(euspinolia.parse_csv(SAMPLE)))

    def test_truncates_long_frames(self):
        text = "n\n" + "".join(f"{i}\n" for i in range(50))
        rendered = repr(euspinolia.parse_csv(text))
        self.assertIn("40 more rows", rendered)
        self.assertIn("[50 rows x 1 columns]", rendered)

    def test_embedded_newlines_do_not_tear_the_table(self):
        df = euspinolia.parse_csv('note,n\n"two\nlines",1\n')
        rendered = repr(df)
        self.assertIn("two\\nlines", rendered)
        # One header line, one row, a blank line and the shape footer.
        self.assertEqual(len(rendered.splitlines()), 4)
        # The escaping is display-only; the value itself is untouched.
        self.assertEqual(df["note"][0], "two\nlines")

    def test_column_repr_names_its_type(self):
        rendered = repr(euspinolia.parse_csv(SAMPLE)["age"])
        self.assertIn("'age'", rendered)
        self.assertIn("int", rendered)


class TestLargeInput(unittest.TestCase):
    def test_many_rows(self):
        rows = 20_000
        text = "id,name,score\n" + "".join(f"{i},user{i},{i}.5\n" for i in range(rows))

        df = euspinolia.parse_csv(text)
        self.assertEqual(df.shape, (rows, 3))
        self.assertEqual(df["id"][-1], rows - 1)
        self.assertEqual(df["name"][-1], f"user{rows - 1}")
        self.assertEqual(df["score"][-1], rows - 1 + 0.5)


if __name__ == "__main__":
    unittest.main()
