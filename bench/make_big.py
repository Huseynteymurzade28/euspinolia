"""Generate the CSV the benchmark reads.

    python3 bench/make_big.py [rows] [path]

Defaults to 500,000 rows written to data/big.csv (data/ is gitignored).
"""

import random
import sys
from pathlib import Path

rows = int(sys.argv[1]) if len(sys.argv) > 1 else 500_000
path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("data/big.csv")
departments = ["eng", "sales", "design", "ops", "research"]
random.seed(0)

path.parent.mkdir(parents=True, exist_ok=True)
with path.open("w", encoding="utf-8") as out:
    out.write("id,name,dept,salary,score\n")
    for i in range(rows):
        out.write(
            f"{i},user{i},{random.choice(departments)},"
            f"{random.randrange(40_000, 200_000)},{random.uniform(0, 100):.2f}\n"
        )

print(f"wrote {path} with {rows} rows ({path.stat().st_size / 1e6:.1f} MB)")
