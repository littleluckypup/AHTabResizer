# AH Tab Resizer

A lightweight World of Warcraft addon that lets you scale, widen, or shrink **all** tabs along the bottom of the Auction House frame—including both Blizzard's default tabs and extra tabs added by third-party addons.

## Features

- **Resizes Every Bottom Tab:** Works on Blizzard's default tabs as well as third-party Auction House addons (Auctionator, `LibAHTab-1-0`, Journalator, and custom bottom-row tabs).
- **Live Movable Resizer Window:** Adjust sliders while looking directly at the Auction House so you can preview changes in real time—no Blizzard Options menu blocking your screen.
- **Quick AH Title-Bar Button:** Adds a compact **Tab Size** button next to the Auction House close button (can be hidden anytime from the menu or via `/ahtabs button`).
- **Flexible Sizing Controls:**
  - **Tab Scale:** `0.50x` to `1.50x` (scales width, height, and label text together)
  - **Auto-Width Padding:** `-20 px` to `+60 px` (tighten or expand auto-fitted tab labels)
  - **Fixed Tab Width:** `35 px` to `250 px` (lock every tab to a uniform pixel width)
  - **Mouse-Wheel Support:** Hover over any slider and scroll for fine adjustments.
- **Zero Dependencies & Secret-Safe:** Pure Lua with no required libraries, built to run cleanly on modern Retail and WoW: Forever without triggering protected-frame or secret-value errors.

## Supported World of Warcraft Versions

- **Retail (Midnight 12.1.5)**
- **WoW: Forever (1.60.1)**
- **Mists of Pandaria Classic**
- **The Burning Crusade Classic Anniversary**
- **Classic Era**

## Usage

Open any Auction House and click the **Tab Size** button in the top-right title bar, or use slash commands in chat:

| Command | Description |
| :--- | :--- |
| `/ahtabs` | Toggle the movable live resizer window |
| `/ahtabs button` | Show or hide the **Tab Size** button on the Auction House |
| `/ahtabs scale 0.85` | Set overall tab scale (`0.50` to `1.50`) |
| `/ahtabs width 80` | Lock every tab to a fixed pixel width (`35` to `250`), or `auto` |
| `/ahtabs padding -10` | Adjust horizontal padding around auto-fitted text (`-20` to `60`) |
| `/ahtabs debug` | Print all detected Auction House tabs, widths, and parents in chat |
| `/ahtabs reset` | Restore all settings and tab dimensions to Blizzard defaults |

## Installation

### CurseForge App (Recommended)
Search for **AH Tab Resizer** in the CurseForge app and click **Install**.

### Manual Installation
1. Download the latest release `.zip` from the [Releases](../../releases) page.
2. Extract the `AHTabResizer` folder into your WoW client's `Interface/AddOns/` directory (e.g. `_retail_`, `_forever_`, `_classic_`, `_anniversary_`, or `_classic_era_`).
3. Restart World of Warcraft and enable **AH Tab Resizer** in the AddOns menu.

## License

Licensed under the [MIT License](LICENSE).