#!/bin/bash

set -e

echo "======================================"
echo " DECAY - Upload da Build via Git LFS"
echo "======================================"

git lfs install

echo "Configurando Git LFS..."

git lfs track "*.so"
git lfs track "*.unity3d"
git lfs track "*.x86_64"
git lfs track "*.assets"
git lfs track "*.bundle"

echo "Configurando .gitignore..."

cat >> .gitignore << 'EOF'

# Unity project generated files
[Ll]ibrary/
[Tt]emp/
[Oo]bj/
[Bb]uild/
[Bb]uilds/
[Ll]ogs/
[Uu]ser[Ss]ettings/

# Unity build debug backups — não enviar
decay_BackUpThisFolder_ButDontShipItWithYourGame/
*_BackUpThisFolder_ButDontShipItWithYourGame/
*.debug

# Visual Studio
.vs/

# OS files
.DS_Store
Thumbs.db
EOF

# Remove do índice caso tenha sido adicionado anteriormente.
git rm -r --cached \
  "decay_BackUpThisFolder_ButDontShipItWithYourGame" \
  2>/dev/null || true

git add .gitattributes
git add .gitignore
git add .

echo "Arquivos LFS:"
git lfs status

echo "Status:"
git status

git commit -m "Update Unity server build" || echo "Nada para commitar."

git push origin main

echo "======================================"
echo " Atualização enviada com sucesso!"
echo "======================================"