#!/bin/bash
# ============================================================
#  Servidor Dedicado – Decay  (lançador para systemd)
#
#  Este script sobe UMA execução do servidor em primeiro plano.
#  Quem reinicia em caso de crash é o systemd (Restart=always).
#  NÃO faça loop de restart aqui — deixe o systemd cuidar disso.
#
#  Comandos de console são enviados via FIFO de entrada:
#     echo "adminset Joao true" > /home/ubuntu/servidordecay/.server_in.fifo
#  ou use o helper:  ./decaycmd adminset Joao true
# ============================================================

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="decay.x86_64"
APP="$DIR/$APP_NAME"
LOG_DIR="$DIR/logs"
IN_FIFO="$DIR/.server_in.fifo"
MAX_LOGS=14   # dias de log retidos

# ── Garantias mínimas a cada inicialização ──────────────────
# (Permissões "pesadas" de deploy ficam no install.sh; aqui só o essencial.)
[[ ! -f "$APP" ]] && { echo "Executável não encontrado: $APP" >&2; exit 1; }
chmod +x "$APP" 2>/dev/null
mkdir -p "$LOG_DIR"

# Limpa logs antigos
find "$LOG_DIR" -name "server_*.log" -mtime +$MAX_LOGS -delete 2>/dev/null

LOG_FILE="$LOG_DIR/server_$(date '+%Y-%m-%d_%H-%M-%S').log"

# ── FIFO de entrada (stdin do servidor) ─────────────────────
# Recria sempre limpo.
rm -f "$IN_FIFO"
mkfifo "$IN_FIFO"
chmod 660 "$IN_FIFO"

# Mantém a ponta de ESCRITA do FIFO aberta o tempo todo.
# Sem isso, o primeiro `echo` que terminar fecharia o pipe e o servidor
# receberia EOF no stdin (Console.ReadLine() retornaria null pra sempre).
sleep infinity > "$IN_FIFO" &
HOLDER_PID=$!

# ── Limpeza ao encerrar ─────────────────────────────────────
cleanup() {
    # Encerra o servidor se ainda estiver vivo
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
    # Encerra o holder do FIFO
    kill "$HOLDER_PID" 2>/dev/null
    rm -f "$IN_FIFO"
}
trap cleanup SIGTERM SIGINT EXIT

echo "══════════════════════════════════════════"
echo "[$(date '+%F %T')] Iniciando Decay Server"
echo "Log: $LOG_FILE"
echo "FIFO de comandos: $IN_FIFO"
echo "══════════════════════════════════════════"

# ── Sobe o servidor ─────────────────────────────────────────
#  stdin  ← FIFO de entrada (comandos do console)
#  stdout ← tela (journald captura) + arquivo de log via tee
#
#  Importante: o servidor NÃO está em pipeline de stdin, então o FIFO
#  funciona como teclado virtual. O stdout passa por tee para gravar log.
"$APP" \
    -batchmode \
    -nographics \
    -logFile - \
    < "$IN_FIFO" \
    2>&1 | tee "$LOG_FILE" &

# PID do servidor é o primeiro processo do pipeline (o $APP).
SERVER_PID=$(jobs -p %1 2>/dev/null)
# Fallback: pega pelo nome se o jobs não resolver.
[[ -z "$SERVER_PID" ]] && SERVER_PID=$(pgrep -f "$APP_NAME" | head -n1)
echo "[$(date '+%F %T')] PID do servidor: $SERVER_PID"

# Espera o servidor (e o tee) terminarem. Quando o servidor cair,
# este script sai e o systemd reinicia tudo.
wait

EXIT_CODE=$?
echo "[$(date '+%F %T')] Servidor encerrou (exit $EXIT_CODE)."
exit $EXIT_CODE