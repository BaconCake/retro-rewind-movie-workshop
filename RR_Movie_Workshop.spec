# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec file for Retro Rewind Movie Workshop
# 
# BUILD COMMAND:
#   pyinstaller RR_Movie_Workshop.spec
#
# PREREQUISITES:
#   pip install pyinstaller pillow
#
# OUTPUT:
#   dist/RR_Movie_Workshop/RR_Movie_Workshop.exe  (folder mode — more reliable than onefile)

import sys
import os

block_cipher = None

a = Analysis(
    ['RR_VHS_Tool.py'],
    pathex=[],
    binaries=[],
    datas=[],
    hiddenimports=[
        'PIL',
        'PIL.Image',
        'PIL.ImageTk',
        'PIL.ImageDraw',
        'PIL.ImageChops',
        'tkinter',
        'tkinter.ttk',
        'tkinter.filedialog',
        'tkinter.messagebox',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        'matplotlib',
        'numpy',
        'scipy',
        'pandas',
        'pytest',
        'setuptools',
        'pip',
        'wheel',
        'unittest',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='RR_Movie_Workshop',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,       # Keep console for debug output during beta
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    # icon='icon.ico',  # Uncomment and add an icon file if you have one
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='RR_Movie_Workshop',
)
