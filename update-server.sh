#!/bin/bash

set -e

echo "======================================"
echo " DECAY - Upload da Build via Git LFS"
echo "======================================"

echo ""
echo "Verificando Git LFS..."
git lfs install

echo ""
echo "Configurando arquivos grandes para Git LFS..."

git lfs track "*.so"
git lfs track "*.unity3d"
git lfs track "*.x86_64"
git lfs track "*.assets"
git lfs track "*.bundle"

echo ""
echo "Configurando .gitignore..."

cat >> .gitignore << 'EOF'

# Unity generated files
[Ll]ibrary/
[Tt]emp/
[Oo]bj/
[Bb]uild/
[Bb]uilds/
[Ll]ogs/
[Uu]ser[Ss]ettings/

# Visual Studio
.vs/

# OS files
.DS_Store
Thumbs.db
EOF

echo ""
echo "Adicionando configurações..."
git add .gitattributes
git add .gitignore

echo ""
echo "Verificando arquivos LFS..."
git lfs ls-files

echo ""
echo "Adicionando arquivos..."
git add .

echo ""
echo "Status:"
git status

echo ""
echo "Arquivos que serão enviados via LFS:"
git lfs status

echo ""
echo "Criando commit..."
git commit -m "Update Unity server build2" || echo "Nada para commitar."

echo ""
echo "Enviando para GitHub..."
git push origin main

echo ""
echo "======================================"
echo " Atualização enviada com sucesso!"
echo "======================================"