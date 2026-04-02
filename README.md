# Deckstacy Proxy Maker

Windows PowerShell + WinForms desktop utility for processing MTG decklists into local organized card image folders.

> [!IMPORTANT]
> The GitHub Pages site at `https://shawnzyp.github.io/Deckstacy-Proxy-Maker/` is documentation only.
> This project is **not** a browser app; there are no web controls on that page.
> To use Deckstacy Proxy Maker, run it locally on Windows (see **Run** below).

## Run

1. Click **Code → Download ZIP** (or clone this repository).
2. Extract the folder locally on Windows.
3. Double-click `Launch-Deckstacy.bat`.

If PowerShell asks for permission, allow the script so the WinForms UI can open.

## Workflow

1. Paste/load a decklist with quantity-prefixed lines (`1 Sol Ring`) and optional section headers.
2. Set deck name, output root, image type, and optional preferred set.
3. Toggle **Only Missing** and/or **Repair Mode** if needed.
4. Click **Download Images**.

## Storage

- `MASTER_CARD_DATABASE/images/front`
- `MASTER_CARD_DATABASE/images/back`
- `MASTER_CARD_DATABASE/metadata/card_index.json`
- `MASTER_CARD_DATABASE/metadata/ambiguity_memory.json`
- `MASTER_CARD_DATABASE/metadata/canonical_memory.json`

Each deck folder includes `front`, `back`, decklist snapshot, manifest, and per-run logs under `runs/run_YYYYMMDD_HHMMSS`.
