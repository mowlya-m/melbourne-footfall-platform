"""Smoke tests asserting the repository scaffold is intact.

These are deliberately trivial. Their job is to prove the CI pipeline
runs end to end before any real source code exists, and to catch the
accidental deletion of a directory the build depends on.
"""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

REQUIRED_DIRECTORIES = [
    "docs/decisions",
    "infra/modules/ingestion",
    "infra/modules/storage",
    "infra/modules/streaming",
    "infra/envs/dev",
    "src/producer",
    "src/glue_jobs",
    "transforms/models/marts",
    "tests/unit",
    "scripts",
]

REQUIRED_FILES = [
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    ".gitignore",
    ".pre-commit-config.yaml",
    "requirements-dev.txt",
    ".github/CODEOWNERS",
    ".github/PULL_REQUEST_TEMPLATE.md",
]


def test_repo_root_resolves() -> None:
    assert (REPO_ROOT / "README.md").exists(), f"Unexpected repo root: {REPO_ROOT}"


def test_required_directories_exist() -> None:
    missing = [d for d in REQUIRED_DIRECTORIES if not (REPO_ROOT / d).is_dir()]
    assert not missing, f"Missing directories: {missing}"


def test_required_files_exist() -> None:
    missing = [f for f in REQUIRED_FILES if not (REPO_ROOT / f).is_file()]
    assert not missing, f"Missing files: {missing}"


def test_no_real_env_file_committed() -> None:
    """A committed .env would mean credentials leaked into git."""
    assert not (REPO_ROOT / ".env").exists(), ".env must never be committed"


def test_readme_documents_the_poll_to_stream_adapter() -> None:
    """The honest framing of the streaming layer must stay in the README."""
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8").lower()
    assert "poll-to-stream" in readme
