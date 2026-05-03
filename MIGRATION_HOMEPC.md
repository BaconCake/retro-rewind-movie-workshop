# Cross-machine migration — one-shot setup for the home PC

Throwaway document. Delete after the home PC is up and running.

## Prerequisites on the home PC

- **GitHub Desktop** — https://desktop.github.com — sign in with the same
  account used here.
- **Flutter SDK** 3.22+ with Windows desktop support
  (`flutter config --enable-windows-desktop`).
- **Claude Code** (already installed per current setup).
- The same Windows username (`sasch`) — otherwise the Claude memory folder
  name needs adjusting (see step 4).

## Steps on the home PC

### 1. Clone the repo to the *exact* path

The Claude memory folder name is derived from the project's absolute path.
To avoid renaming, clone into the same path used on the holiday machine:

```
C:\Users\sasch\Documents\MODDING\Retro Rewind\Movie_Workshop\RR Movie Workshop
```

In GitHub Desktop:

1. **File → Clone repository → URL**
2. URL: `https://github.com/BaconCake/retro-rewind-movie-workshop`
3. **Local Path:** browse to / type
   `C:\Users\sasch\Documents\MODDING\Retro Rewind\Movie_Workshop\RR Movie Workshop`
   (the empty folder you already created — GitHub Desktop will clone into it).
4. Clone.

### 2. Restore Claude memory

Move the memory files out of the repo into Claude's per-project store:

```powershell
$repo   = "C:\Users\sasch\Documents\MODDING\Retro Rewind\Movie_Workshop\RR Movie Workshop"
$claude = "$env:USERPROFILE\.claude\projects\C--Users-sasch-Documents-MODDING-Retro-Rewind-Movie-Workshop\memory"

New-Item -ItemType Directory -Force -Path $claude | Out-Null
Copy-Item -Path "$repo\.claude-migration\memory\*.md" -Destination $claude -Force
Get-ChildItem $claude
```

You should see `MEMORY.md`, `project_rr_movie_workshop.md`,
`project_genres.md`, `user_language.md`.

### 3. Local config + Flutter deps

`config.json` is gitignored (per-machine paths). Create one in the project
root with the home PC's paths to `repak.exe`, `texconv.exe`, the base
game pak, and `~mods`. Then:

```powershell
flutter pub get
```

### 4. Smoke test

```powershell
flutter run -d windows
```

Click **Ship to Store**, launch the game, verify it still loads.

### 5. Continue the Claude session

```powershell
claude
```

Memory loads automatically. The session won't auto-resume the conversation
transcript, but all project context is restored. You can pick up by saying
something like *"weiter mit slice 3"* and Claude will know what that means
from `MEMORY.md` and `MIGRATION.md`.

### 6. Clean up the migration folder

Once everything works on the home PC:

- On GitHub.com: delete `.claude-migration/` via the web UI (Browse →
  folder → each file → trash icon → commit), **or**
- Locally on either PC: delete `.claude-migration/` and
  `MIGRATION_HOMEPC.md`, commit, push.

> Note: Even after deletion, Git history retains these files. Content is
> non-sensitive (language preference + project notes, no tokens / secrets),
> so this is acceptable for a public repo.
