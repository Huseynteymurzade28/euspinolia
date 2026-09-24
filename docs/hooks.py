"""MkDocs hook: serve the repo's assets/ folder under the site's assets/.

The logos live in assets/ because the README links them from there by
absolute URL, which PyPI pages rely on; copying them into docs/ would leave
two copies to keep in step.
"""

from pathlib import Path

from mkdocs.structure.files import File

ASSETS = Path(__file__).resolve().parent.parent / "assets"


SERVED = ("logo-black.png", "logo-white.png", "favicon.png")


def on_files(files, config):
    for name in SERVED:
        files.append(File.generated(config, f"assets/{name}", abs_src_path=str(ASSETS / name)))
    return files
