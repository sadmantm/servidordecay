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

echo "Verificando .gitignore existente..."

if [ ! -f .gitignore ]; then
    echo "ERRO: .gitignore não encontrado!"
    echo "Execute este script na raiz do projeto."
    exit 1
fi

# Remove do índice o backup que não deve ser enviado.
git rm -r --cached --ignore-unmatch \
    "decay_BackUpThisFolder_ButDontShipItWithYourGame"

echo "Adicionando arquivos ao Git..."

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