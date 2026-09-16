"""Phase 3-6 tests: reading CSV into a DataFrame from Python, and working on it.

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


class TestAggregates(unittest.TestCase):
    def setUp(self):
        self.df = euspinolia.parse_csv(SAMPLE)

    def test_integer_column(self):
        age = self.df["age"]
        self.assertEqual(age.sum(), 110)
        self.assertEqual(age.min(), 29)
        self.assertEqual(age.max(), 45)
        self.assertAlmostEqual(age.mean(), 110 / 3)

    def test_float_column(self):
        score = self.df["score"]
        self.assertAlmostEqual(score.sum(), 252.75)
        self.assertEqual(score.min(), 73.25)
        self.assertEqual(score.max(), 91.5)
        self.assertAlmostEqual(score.mean(), 84.25)

    def test_integer_results_stay_integers(self):
        self.assertIsInstance(self.df["age"].sum(), int)
        self.assertIsInstance(self.df["age"].min(), int)
        self.assertIsInstance(self.df["score"].sum(), float)

    def test_mean_is_always_a_float(self):
        self.assertIsInstance(self.df["age"].mean(), float)

    def test_matches_python(self):
        values = self.df["score"].to_list()
        self.assertAlmostEqual(self.df["score"].sum(), sum(values))
        self.assertEqual(self.df["score"].min(), min(values))
        self.assertEqual(self.df["score"].max(), max(values))

    def test_large_integers_stay_exact(self):
        # Beyond 2**53 a float round trip would lose the last digits.
        big = 2**60 + 1
        df = euspinolia.parse_csv(f"n\n{big}\n{big}\n")
        self.assertEqual(df["n"].sum(), 2 * big)

    def test_sum_beyond_i64_raises(self):
        limit = 2**63 - 1
        df = euspinolia.parse_csv(f"n\n{limit}\n1\n")
        with self.assertRaises(OverflowError):
            df["n"].sum()

    def test_mean_survives_a_total_that_would_not(self):
        limit = 2**63 - 1
        df = euspinolia.parse_csv(f"n\n{limit}\n{limit}\n")
        self.assertAlmostEqual(df["n"].mean(), float(limit))

    def test_string_column_refuses(self):
        for reduction in ("sum", "min", "max", "mean"):
            with self.subTest(reduction=reduction):
                with self.assertRaises(TypeError):
                    getattr(self.df["name"], reduction)()

    def test_empty_column_has_no_extremes(self):
        df = euspinolia.parse_csv("n\n")
        # A header-only file infers as string, so this reports the type first.
        with self.assertRaises(TypeError):
            df["n"].mean()

    def test_reductions_need_an_open_frame(self):
        df = euspinolia.parse_csv("n\n1\n")
        column = df["n"]
        df.close()
        with self.assertRaises(ValueError):
            column.sum()


class TestFilter(unittest.TestCase):
    def setUp(self):
        self.df = euspinolia.parse_csv(SAMPLE)

    def test_filter_returns_a_new_frame(self):
        adults = self.df.filter("age", ">", 30)
        self.assertIsInstance(adults, euspinolia.DataFrame)
        self.assertEqual(adults.shape, (2, 3))
        self.assertEqual(adults["name"].to_list(), ["ada", "grace"])
        self.assertEqual(adults["age"].to_list(), [36, 45])
        self.assertEqual(adults["score"].to_list(), [91.5, 88.0])
        # The source is untouched.
        self.assertEqual(self.df.shape, (3, 3))

    def test_every_operator(self):
        cases = {
            "==": [36],
            "!=": [45, 29],
            "<": [29],
            "<=": [36, 29],
            ">": [45],
            ">=": [36, 45],
        }
        for op, expected in cases.items():
            with self.subTest(op=op):
                self.assertEqual(self.df.filter("age", op, 36)["age"].to_list(), expected)

    def test_by_column_position(self):
        self.assertEqual(self.df.filter(1, ">", 30).shape, (2, 3))

    def test_float_column(self):
        self.assertEqual(self.df.filter("score", "<", 90.0)["name"].to_list(), ["grace", "Doe, John"])

    def test_string_column(self):
        self.assertEqual(self.df.filter("name", "==", "grace")["age"].to_list(), [45])
        self.assertEqual(self.df.filter("name", "<", "b")["name"].to_list(), ["ada", "Doe, John"])

    def test_numbers_compare_across_int_and_float(self):
        self.assertEqual(self.df.filter("age", ">", 35.5)["age"].to_list(), [36, 45])
        self.assertEqual(self.df.filter("score", "==", 88)["name"].to_list(), ["grace"])

    def test_nothing_matching_keeps_the_types(self):
        empty = self.df.filter("age", ">", 100)
        self.assertEqual(empty.shape, (0, 3))
        self.assertEqual(empty.dtypes, self.df.dtypes)
        self.assertEqual(empty["age"].to_list(), [])
        self.assertEqual(empty.head(), [])

    def test_everything_matching_is_still_a_copy(self):
        everything = self.df.filter("age", ">", 0)
        self.assertIsNot(everything, self.df)
        self.assertEqual(everything["name"].to_list(), self.df["name"].to_list())

    def test_result_outlives_the_source(self):
        adults = self.df.filter("age", ">", 30)
        self.df.close()
        gc.collect()
        self.assertEqual(adults["name"].to_list(), ["ada", "grace"])

    def test_result_can_be_filtered_again(self):
        narrowed = self.df.filter("age", ">", 30).filter("score", "<", 90)
        self.assertEqual(narrowed["name"].to_list(), ["grace"])

    def test_unicode_value(self):
        df = euspinolia.parse_csv("city\nİstanbul\nİzmir\n")
        self.assertEqual(df.filter("city", "==", "İzmir")["city"].to_list(), ["İzmir"])

    def test_text_against_number_raises(self):
        with self.assertRaises(TypeError):
            self.df.filter("name", ">", 3)
        with self.assertRaises(TypeError):
            self.df.filter("age", "==", "36")

    def test_unsupported_value_types_raise(self):
        with self.assertRaises(TypeError):
            self.df.filter("age", "==", None)
        # There is no bool column type, so this is almost certainly a mistake.
        with self.assertRaises(TypeError):
            self.df.filter("age", "==", True)

    def test_unknown_operator_raises(self):
        with self.assertRaises(ValueError):
            self.df.filter("age", "=", 36)

    def test_unknown_column_raises(self):
        with self.assertRaises(KeyError):
            self.df.filter("missing", "==", 1)
        with self.assertRaises(IndexError):
            self.df.filter(9, "==", 1)

    def test_needs_an_open_frame(self):
        self.df.close()
        with self.assertRaises(ValueError):
            self.df.filter("age", ">", 30)


class TestConditions(unittest.TestCase):
    def setUp(self):
        self.df = euspinolia.parse_csv(SAMPLE)

    def test_comparison_builds_a_condition(self):
        condition = self.df["age"] > 30
        self.assertIsInstance(condition, euspinolia.Condition)
        self.assertEqual(repr(condition), "Condition(age > 30)")

    def test_indexing_with_a_condition_filters(self):
        adults = self.df[self.df["age"] > 30]
        self.assertEqual(adults["name"].to_list(), ["ada", "grace"])

    def test_every_operator(self):
        age = self.df["age"]
        cases = [
            (age == 36, [36]),
            (age != 36, [45, 29]),
            (age < 36, [29]),
            (age <= 36, [36, 29]),
            (age > 36, [45]),
            (age >= 36, [36, 45]),
        ]
        for condition, expected in cases:
            with self.subTest(condition=repr(condition)):
                self.assertEqual(self.df[condition]["age"].to_list(), expected)

    def test_matches_filter(self):
        by_call = self.df.filter("score", ">=", 88.0)
        by_operator = self.df[self.df["score"] >= 88.0]
        self.assertEqual(by_call.head(), by_operator.head())

    def test_string_comparison(self):
        self.assertEqual(self.df[self.df["name"] == "grace"]["age"].to_list(), [45])

    def test_and_combines_conditions(self):
        both = self.df[(self.df["age"] > 30) & (self.df["score"] < 90)]
        self.assertEqual(both["name"].to_list(), ["grace"])

    def test_and_of_three(self):
        df = self.df
        result = df[(df["age"] > 20) & (df["age"] < 40) & (df["name"] != "ada")]
        self.assertEqual(result["name"].to_list(), ["Doe, John"])

    def test_or_is_not_supported(self):
        with self.assertRaises(TypeError):
            (self.df["age"] > 30) | (self.df["age"] < 30)

    def test_condition_has_no_truth_value(self):
        with self.assertRaises(TypeError):
            bool(self.df["age"] > 30)
        with self.assertRaises(TypeError):
            # `and` calls bool() on the left side.
            (self.df["age"] > 30) and (self.df["age"] < 40)

    def test_condition_is_bound_to_its_frame(self):
        other = euspinolia.parse_csv(SAMPLE)
        with self.assertRaises(ValueError):
            self.df[other["age"] > 30]
        with self.assertRaises(ValueError):
            (self.df["age"] > 30) & (other["age"] < 40)

    def test_columns_are_not_hashable(self):
        # `==` builds a Condition, so equality is not identity and there is
        # no hash to go with it.
        with self.assertRaises(TypeError):
            hash(self.df["age"])


GROUPED = (
    "city,n,x\n"
    "paris,1,0.5\n"
    "rome,2,1.5\n"
    "paris,3,2.5\n"
    "berlin,4,3.5\n"
    "rome,5,4.5\n"
)


class TestGroupBy(unittest.TestCase):
    def setUp(self):
        self.df = euspinolia.parse_csv(GROUPED)

    def test_groupby_is_lazy(self):
        grouped = self.df.groupby("city")
        self.assertIsInstance(grouped, euspinolia.GroupBy)
        self.assertEqual(grouped.key, "city")
        self.assertEqual(repr(grouped), "GroupBy('city', 5 rows)")

    def test_agg_one_column(self):
        out = self.df.groupby("city").agg({"n": "sum"})
        self.assertIsInstance(out, euspinolia.DataFrame)
        self.assertEqual(out.columns, ("city", "n"))
        self.assertEqual(out["city"].to_list(), ["paris", "rome", "berlin"])
        self.assertEqual(out["n"].to_list(), [4, 7, 4])

    def test_groups_appear_in_first_seen_order(self):
        out = self.df.groupby("city").count()
        self.assertEqual(out["city"].to_list(), ["paris", "rome", "berlin"])

    def test_every_function(self):
        out = self.df.groupby("city").agg({"n": "mean", "x": "max"})
        self.assertEqual(out.columns, ("city", "n", "x"))
        self.assertEqual(out["n"].to_list(), [2.0, 3.5, 4.0])
        self.assertEqual(out["x"].to_list(), [2.5, 4.5, 3.5])

        self.assertEqual(self.df.groupby("city").agg({"n": "min"})["n"].to_list(), [1, 2, 4])
        self.assertEqual(self.df.groupby("city").agg({"x": "sum"})["x"].to_list(), [3.0, 6.0, 3.5])

    def test_result_types(self):
        out = self.df.groupby("city").agg({"n": "sum", "x": "mean"})
        self.assertEqual(
            out.dtypes,
            (euspinolia.ColumnType.STRING, euspinolia.ColumnType.INT, euspinolia.ColumnType.FLOAT),
        )
        self.assertIsInstance(out["n"][0], int)

        means = self.df.groupby("city").agg({"n": "mean"})
        self.assertIs(means["n"].dtype, euspinolia.ColumnType.FLOAT)

    def test_count(self):
        out = self.df.groupby("city").count()
        self.assertEqual(out.columns, ("city", "count"))
        self.assertEqual(out["count"].to_list(), [2, 2, 1])
        # `count` accepts any column, including text and the key itself.
        self.assertEqual(self.df.groupby("city").agg({"city": "count"})["count"].to_list(), [2, 2, 1])

    def test_shortcuts_cover_the_numeric_columns(self):
        out = self.df.groupby("city").sum()
        self.assertEqual(out.columns, ("city", "n", "x"))
        self.assertEqual(out["n"].to_list(), [4, 7, 4])

        self.assertEqual(self.df.groupby("city").mean()["x"].to_list(), [1.5, 3.0, 3.5])
        self.assertEqual(self.df.groupby("city").min()["n"].to_list(), [1, 2, 4])
        self.assertEqual(self.df.groupby("city").max()["n"].to_list(), [3, 5, 4])

    def test_numeric_key(self):
        df = euspinolia.parse_csv("k,v\n2,10\n1,20\n2,30\n")
        out = df.groupby("k").agg({"v": "sum"})
        self.assertEqual(out["k"].to_list(), [2, 1])
        self.assertEqual(out["v"].to_list(), [40, 20])
        self.assertIs(out["k"].dtype, euspinolia.ColumnType.INT)

    def test_float_key(self):
        df = euspinolia.parse_csv("k,v\n0.5,1\n1.5,2\n0.5,3\n")
        out = df.groupby("k").count()
        self.assertEqual(out["k"].to_list(), [0.5, 1.5])
        self.assertEqual(out["count"].to_list(), [2, 1])

    def test_key_by_position(self):
        self.assertEqual(self.df.groupby(0).count()["count"].to_list(), [2, 2, 1])

    def test_shortcuts_skip_string_columns(self):
        df = euspinolia.parse_csv("k,s,n\na,x,1\na,y,2\n")
        out = df.groupby("k").sum()
        self.assertEqual(out.columns, ("k", "n"))

    def test_no_specs_gives_the_distinct_keys(self):
        out = self.df.groupby("city").agg({})
        self.assertEqual(out.columns, ("city",))
        self.assertEqual(out["city"].to_list(), ["paris", "rome", "berlin"])

    def test_empty_frame(self):
        df = euspinolia.parse_csv("k,v\n")
        out = df.groupby("k").count()
        self.assertEqual(out.shape, (0, 2))
        self.assertEqual(out["count"].to_list(), [])

    def test_composes_with_filter(self):
        out = self.df[self.df["n"] > 1].groupby("city").count()
        self.assertEqual(out["city"].to_list(), ["rome", "paris", "berlin"])
        self.assertEqual(out["count"].to_list(), [2, 1, 1])

    def test_result_outlives_the_source(self):
        out = self.df.groupby("city").agg({"n": "sum"})
        self.df.close()
        gc.collect()
        self.assertEqual(out["n"].to_list(), [4, 7, 4])

    def test_matches_python(self):
        expected: dict[str, list[float]] = {}
        for city, x in zip(self.df["city"], self.df["x"]):
            expected.setdefault(city, []).append(x)
        out = self.df.groupby("city").agg({"x": "mean"})
        for city, mean in zip(out["city"], out["x"]):
            self.assertAlmostEqual(mean, sum(expected[city]) / len(expected[city]))

    def test_sum_overflow_raises(self):
        limit = 2**63 - 1
        df = euspinolia.parse_csv(f"k,n\na,{limit}\na,1\n")
        with self.assertRaises(OverflowError):
            df.groupby("k").sum()

    def test_arithmetic_on_text_raises(self):
        for func in ("sum", "mean", "min", "max"):
            with self.subTest(func=func):
                with self.assertRaises(TypeError):
                    self.df.groupby("n").agg({"city": func})

    def test_aggregating_the_key_raises(self):
        with self.assertRaises(ValueError):
            self.df.groupby("n").agg({"n": "sum"})

    def test_unknown_function_raises(self):
        with self.assertRaises(ValueError):
            self.df.groupby("city").agg({"n": "median"})

    def test_unknown_column_raises(self):
        with self.assertRaises(KeyError):
            self.df.groupby("missing")
        with self.assertRaises(KeyError):
            self.df.groupby("city").agg({"missing": "sum"})

    def test_needs_an_open_frame(self):
        grouped = self.df.groupby("city")
        self.df.close()
        with self.assertRaises(ValueError):
            grouped.count()


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


class TestToCsv(unittest.TestCase):
    def test_returns_the_csv_as_a_string(self):
        df = euspinolia.parse_csv(SAMPLE)
        self.assertEqual(df.to_csv(), SAMPLE)

    def test_writes_a_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "out.csv"
            df = euspinolia.parse_csv(SAMPLE)
            self.assertIsNone(df.to_csv(path))
            self.assertEqual(path.read_text(encoding="utf-8"), SAMPLE)

    def test_accepts_a_path_string(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "out.csv"
            euspinolia.parse_csv("a\n1\n").to_csv(str(path))
            self.assertEqual(path.read_text(encoding="utf-8"), "a\n1\n")

    def test_quotes_only_what_needs_it(self):
        df = euspinolia.parse_csv('s\n"a,b"\n"say ""hi"""\n"two\nlines"\nplain\n')
        self.assertEqual(df.to_csv(), 's\n"a,b"\n"say ""hi"""\n"two\nlines"\nplain\n')

    def test_round_trips_types(self):
        df = euspinolia.parse_csv("n,x,s\n1,2.0,ada\n-2,0.5,\n")
        again = euspinolia.parse_csv(df.to_csv())
        self.assertEqual(again.dtypes, df.dtypes)
        self.assertEqual(again["n"].to_list(), [1, -2])
        self.assertEqual(again["x"].to_list(), [2.0, 0.5])
        self.assertEqual(again["s"].to_list(), ["ada", ""])

    def test_derived_frames_write_too(self):
        df = euspinolia.parse_csv(SAMPLE)
        self.assertEqual(df[df["age"] > 40].to_csv(), "name,age,score\ngrace,45,88.0\n")
        self.assertEqual(
            df.groupby("age").agg({"score": "sum"}).to_csv(),
            "age,score\n36,91.5\n45,88.0\n29,73.25\n",
        )

    def test_header_only(self):
        self.assertEqual(euspinolia.parse_csv("a,b\n").to_csv(), "a,b\n")

    def test_unicode_survives(self):
        df = euspinolia.parse_csv("şehir\nİstanbul\n")
        self.assertEqual(df.to_csv(), "şehir\nİstanbul\n")

    def test_needs_an_open_frame(self):
        df = euspinolia.parse_csv("a\n1\n")
        df.close()
        with self.assertRaises(ValueError):
            df.to_csv()


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
