#!/bin/bash

set -e

echo "Verificando Git LFS..."
git lfs install

echo "Garantindo rastreamento de arquivos grandes..."
git lfs track "*.so"
git lfs track "*.unity3d"
git lfs track "*.x86_64"

echo "Adicionando arquivos..."
git add .gitattributes
git add .

echo "Status:"
git status

echo "Criando commit..."
git commit -m "Update Unity server build" || echo "Nada para commitar."

echo "Enviando para GitHub..."
git push origin main

echo "Atualização enviada com sucesso."