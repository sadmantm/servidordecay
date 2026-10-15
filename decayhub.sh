#!/bin/bash
# ============================================================
#  decayhub.sh — Painel único do Servidor Dedicado Decay
#
#  MODOS:
#    ./decayhub.sh            → menu interativo (painel)
#    ./decayhub.sh __run      → LANÇADOR (uso interno do systemd)
#    ./decayhub.sh __prompt   → prompt de comandos (uso interno do tmux)
#    ./decayhub.sh __tail     → seguidor de log  (uso interno do tmux)
#    ./decayhub.sh __restart  → reinício programado (uso interno do timer)
#
#  ENCERRAMENTO SEGURO
#    O painel NÃO depende de o Unity tratar SIGTERM. Ele envia o comando
#    de console CMD_ENCERRAR pela FIFO; o próprio jogo bloqueia conexões,
#    salva mundo + players + corpos com o servidor ainda ativo e sai.
#    SIGTERM e SIGKILL ficam como planos B e C, com prazos maiores que o
#    tempo real do save.
#
#  COMANDOS DE CONSOLE (DedicatedServerConsole)
#    stop [s]      salva e sai (o systemd reinicia)
#    shutdown [s]  salva e sai com código 64 (o systemd NÃO reinicia)
#    save          dispara save do mundo + flush dos players
#    say <texto>   anuncia no chat
#    status        players, FPS, heap, objetos
# ============================================================

set -u

# ── Configuração autodetectada ──────────────────────────────
SERVER_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
USER_OWNER="$(stat -c '%U' "$SERVER_DIR" 2>/dev/null || id -un)"
GROUP_OWNER="$(stat -c '%G' "$SERVER_DIR" 2>/dev/null || id -gn)"

APP_NAME="decay.x86_64"
SERVICE_NAME="decay-server"

APP="$SERVER_DIR/$APP_NAME"
CONFIG_JSON="$SERVER_DIR/server_config.json"
LOG_DIR="$SERVER_DIR/logs"
BACKUP_DIR="$SERVER_DIR/backups"
CURRENT_LOG="$LOG_DIR/current.log"
IN_FIFO="$SERVER_DIR/.server_in.fifo"
SELF="$(readlink -f "$0")"
UNIT_PATH="/etc/systemd/system/$SERVICE_NAME.service"
SYSCTL_PATH="/etc/sysctl.d/99-decay.conf"
TMUX_SESSION="decay_console"

LOG_RETENTION_DAYS=14
BACKUP_RETENTION=20

# Pastas de save geradas pelo jogo (irmãs de <app>_Data).
SAVE_DIRS=("WorldSaves" "PlayerSaves")

# ── Timeouts de encerramento ────────────────────────────────
# Sequência do encerramento (wrapper):
#   1) envia CMD_ENCERRAR pela FIFO → o JOGO salva tudo e sai sozinho
#   2) sem saída em STOP_WAIT_GRACIOSO s → SIGTERM (plano B)
#   3) sem saída em mais STOP_WAIT_TERM s → SIGKILL (plano C, save perdido)
#
# O total do wrapper precisa ser MENOR que o TimeoutStopSec do systemd,
# senão o systemd mata no meio da espera.
#
# Meça o seu: pare pela opção 3 e veja "Unity encerrou após Xs" no
# journal (journalctl -u decay-server -n 20).
#
# ⚠️ Depois de mudar estes valores, rode a opção 1 (regrava a unit) e
# confira com:  systemctl show decay-server -p TimeoutStopUSec
STOP_WAIT_GRACIOSO=100
STOP_WAIT_TERM=15
STOP_WAIT_WRAPPER=$(( STOP_WAIT_GRACIOSO + STOP_WAIT_TERM ))
STOP_WAIT_SYSTEMD=150

# Comando de console que faz o JOGO salvar e sair (DedicatedServerConsole).
# 0 = sem contagem regressiva (os avisos, quando há, já foram dados antes).
CMD_ENCERRAR="stop 0"

# Código de saída do comando 'shutdown': o systemd NÃO reinicia.
EXIT_DESLIGAR=64

# Tempo máximo esperando a nova sessão liberar conexões após um reinício
# (inclui a restauração do mundo).
ESPERA_PRONTO_S=900

# ⚠️ ERA 4096. Swap grande é o que produziu a espiral de thrashing:
# o GC toca o heap inteiro, as páginas voltam do disco, o frame trava,
# o kcp para de tickar e TODOS os clientes estouram o timeout juntos.
# Aqui swap é rede de segurança contra OOM, não memória de trabalho.
SWAP_FILE="/swapfile_decay"
SWAP_SIZE_MB=2048

# ── Reinício programado ─────────────────────────────────────
# Hora LOCAL do sistema (o painel define America/Sao_Paulo).
# O reinício acontece EXATAMENTE neste horário; o timer dispara antes
# para dar tempo aos avisos.
RESTART_HORARIO="06:00"

# Minutos de antecedência dos avisos, em ordem DECRESCENTE. () = sem aviso.
RESTART_AVISOS_MIN=(15 10 5 1)

# Pula o reinício se o servidor subiu há menos que isso (ex.: alguém
# reiniciou na mão de madrugada).
RESTART_MIN_UPTIME_H=4

# Comando de CONSOLE que avisa os jogadores no chat. %d = minutos restantes.
# Sem acentos: não depende da codificação do stdin do servidor.
# Vazio = reinicia sem avisar. Não use '%' no texto além do %d.
RESTART_AVISO_CMD="say Servidor reinicia em %d min para manutencao. Seu progresso sera salvo."

# Backup dos saves entre a parada e a subida do reinício programado.
RESTART_COM_BACKUP=1

RESTART_UNIT="decay-restart"

# Lock contra dois reinícios simultâneos (timer + manual).
if [[ -w /run ]]; then
    RESTART_LOCK="/run/decay-restart.lock"
else
    RESTART_LOCK="/tmp/decay-restart.lock"
fi

# ── Cores ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}✔ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
err()  { echo -e "${RED}✘ $*${NC}"; }

# ============================================================
#  MODO LANÇADOR (systemd: decayhub.sh __run)
# ============================================================
run_launcher() {
    [[ ! -f "$APP" ]] && { echo "Executável não encontrado: $APP" >&2; exit 1; }
    chmod +x "$APP" 2>/dev/null

    mkdir -p "$LOG_DIR"
    find "$LOG_DIR" -name "server_*.log" -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null

    local LOG_FILE="$LOG_DIR/server_$(date '+%Y-%m-%d_%H-%M-%S').log"

    # Link estável para o log da sessão atual — é o alvo do 'tail -F'.
    ln -sfn "$LOG_FILE" "$CURRENT_LOG"

    # ── FIFO de comandos ────────────────────────────────────
    # exec 3<> abre a FIFO em LEITURA-ESCRITA num descritor do próprio
    # bash: não bloqueia e mantém o stdin do servidor sem EOF. É também
    # por este descritor que o encerramento envia o comando de 'stop'.
    #
    # ⚠️ Não use um holder 'sleep infinity > fifo &': o 'wait' sem argumento
    # espera TODOS os filhos, e o systemd nunca via o Unity cair.
    rm -f "$IN_FIFO"
    if ! mkfifo -m 660 "$IN_FIFO"; then
        echo "Falha ao criar FIFO em $IN_FIFO" >&2
        exit 1
    fi
    exec 3<>"$IN_FIFO"

    local SERVER_PID=""
    local ENCERRANDO=0
    EXIT_ENCERRAR=""

    # ── Encerramento SEGURO ─────────────────────────────────
    # 1) pede ao JOGO para salvar e sair (comando de console pela FIFO)
    # 2) SIGTERM se ele não sair no prazo
    # 3) SIGKILL como último recurso
    encerrar() {
        [[ "$ENCERRANDO" == "1" ]] && return
        ENCERRANDO=1

        if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
            local INICIO=$SECONDS
            local PID_ALVO="$SERVER_PID"

            echo "[$(date '+%F %T')] Encerramento: enviando '$CMD_ENCERRAR' ao console" \
                 "(save completo + saída limpa). Prazo: ${STOP_WAIT_GRACIOSO}s."

            # fd 3 é a própria FIFO em leitura-escrita: a escrita não bloqueia.
            if ! printf '%s\n' "$CMD_ENCERRAR" >&3 2>/dev/null; then
                echo "[$(date '+%F %T')] Falha ao escrever na FIFO — indo direto ao SIGTERM."
                kill -TERM "$PID_ALVO" 2>/dev/null
            fi

            # Cão de guarda: só age se o jogo NÃO sair sozinho no prazo.
            (
                sleep "$STOP_WAIT_GRACIOSO"
                if kill -0 "$PID_ALVO" 2>/dev/null; then
                    echo "[$(date '+%F %T')] Sem saída em ${STOP_WAIT_GRACIOSO}s. SIGTERM (plano B)."
                    kill -TERM "$PID_ALVO" 2>/dev/null
                    sleep "$STOP_WAIT_TERM"
                    if kill -0 "$PID_ALVO" 2>/dev/null; then
                        echo "[$(date '+%F %T')] SIGKILL — o save final provavelmente foi perdido."
                        kill -KILL "$PID_ALVO" 2>/dev/null
                    fi
                fi
            ) &
            local CAO=$!

            # wait COM argumento: retorna no instante em que o Unity sai.
            wait "$PID_ALVO" 2>/dev/null
            EXIT_ENCERRAR=$?

            kill "$CAO" 2>/dev/null
            wait "$CAO" 2>/dev/null

            echo "[$(date '+%F %T')] Unity encerrou após $(( SECONDS - INICIO ))s" \
                 "(exit $EXIT_ENCERRAR)."
            SERVER_PID=""
        fi

        # ⚠️ Só fecha o fd 3. Um 'exec ... 2>/dev/null' aqui redirecionaria o
        # stderr do PRÓPRIO script para sempre.
        exec 3>&-
        rm -f "$IN_FIFO"
    }
    trap encerrar SIGTERM SIGINT
    trap encerrar EXIT

    echo "══════════════════════════════════════════"
    echo "[$(date '+%F %T')] Iniciando Decay Server"
    echo "Log: $LOG_FILE"
    echo "Encerramento: '$CMD_ENCERRAR' → ${STOP_WAIT_GRACIOSO}s → SIGTERM → ${STOP_WAIT_TERM}s → SIGKILL"
    echo "══════════════════════════════════════════"

    # ⚠️ SEM pipeline e SEM tee: '-logFile <path>' faz o próprio Unity
    # escrever no arquivo. O pipeline tornava o PID e o exit code inúteis.
    "$APP" -batchmode -nographics -logFile "$LOG_FILE" <&3 &
    SERVER_PID=$!

    echo "[$(date '+%F %T')] PID do servidor: $SERVER_PID"

    # wait COM argumento: retorna o exit code real do Unity.
    wait "$SERVER_PID"
    local EXIT_CODE=$?

    # Se o wait foi interrompido por um sinal, o encerrar() já esperou o
    # jogo e guardou o código real dele.
    [[ -n "${EXIT_ENCERRAR:-}" ]] && EXIT_CODE=$EXIT_ENCERRAR
    SERVER_PID=""

    if (( EXIT_CODE == EXIT_DESLIGAR )); then
        echo "[$(date '+%F %T')] Servidor DESLIGADO por comando (exit $EXIT_CODE)" \
             "— o systemd não vai reiniciar."
    else
        echo "[$(date '+%F %T')] Servidor encerrou (exit $EXIT_CODE)."
    fi
    exit $EXIT_CODE
}

# ============================================================
#  HELPERS
# ============================================================
esta_rodando() { systemctl is-active --quiet "$SERVICE_NAME"; }

precisa_sudo() { [[ $EUID -ne 0 ]] && echo "sudo"; }

tem_jq() { command -v jq >/dev/null 2>&1; }

# O ServerConfig grava um header /* ... */ antes do JSON. O Newtonsoft
# ignora comentários; o jq NÃO. Esta função entrega só o JSON.
ler_config() {
    [[ -f "$CONFIG_JSON" ]] || return 1
    sed '/^\/\*/,/^\*\//d' "$CONFIG_JSON"
}

cfg() {
    tem_jq || { echo ""; return; }
    ler_config 2>/dev/null | jq -r "$1 // empty" 2>/dev/null
}

status_curto() {
    if esta_rodando; then
        echo -e "${GREEN}● RODANDO${NC}"
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${YELLOW}○ PARADO${NC} (habilitado no boot)"
    elif [[ -f "$UNIT_PATH" ]]; then
        echo -e "${YELLOW}○ PARADO${NC}"
    else
        echo -e "${RED}✘ NÃO INSTALADO${NC}"
    fi
}

# PID do processo do JOGO. Prefere descer a partir do MainPID do systemd
# em vez de um pgrep solto pela linha de comando.
pid_do_servidor() {
    local main filho
    main=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null)
    if [[ -n "$main" && "$main" != "0" ]]; then
        filho=$(pgrep -P "$main" 2>/dev/null | head -n1)
        [[ -n "$filho" ]] && { echo "$filho"; return; }
    fi
    pgrep -f "$APP" 2>/dev/null | head -n1
}

# ── Thread mais quente do processo ──────────────────────────
# Unity + Mirror rodam o loop de jogo inteiro numa ÚNICA thread. Se ela
# está colada em ~100%, mais vCPU não resolve nada — só core mais rápido
# ou menos trabalho por frame.
thread_mais_quente() {
    local pid="$1" hz t tid linha campos agora d
    local best=0 bestid="" bestname=""
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)

    declare -A antes nomes
    for t in /proc/"$pid"/task/*/stat; do
        [[ -r "$t" ]] || continue
        read -r linha < "$t" 2>/dev/null || continue
        tid="${linha%% *}"
        nomes[$tid]=$(sed 's/^[0-9]* (\(.*\)) .*/\1/' <<< "$linha")
        # remove "pid (comm) " → f[11]=utime, f[12]=stime
        read -r -a campos <<< "${linha#*) }"
        antes[$tid]=$(( ${campos[11]:-0} + ${campos[12]:-0} ))
    done

    sleep 1

    for t in /proc/"$pid"/task/*/stat; do
        [[ -r "$t" ]] || continue
        read -r linha < "$t" 2>/dev/null || continue
        tid="${linha%% *}"
        [[ -z "${antes[$tid]:-}" ]] && continue
        read -r -a campos <<< "${linha#*) }"
        agora=$(( ${campos[11]:-0} + ${campos[12]:-0} ))
        d=$(( (agora - antes[$tid]) * 100 / hz ))
        if (( d > best )); then
            best=$d; bestid=$tid; bestname="${nomes[$tid]:-?}"
        fi
    done

    echo "$best ${bestname:-?} ${bestid:-?}"
}

barra_pct() {
    local pct=${1%.*}; local largura=${2:-20}
    [[ -z "$pct" || ! "$pct" =~ ^[0-9]+$ ]] && pct=0
    (( pct > 100 )) && pct=100
    local cheio=$(( pct * largura / 100 ))
    local cor=$GREEN
    (( pct >= 75 )) && cor=$YELLOW
    (( pct >= 90 )) && cor=$RED
    local b="" i
    for ((i=0; i<cheio; i++)); do b+="█"; done
    for ((i=cheio; i<largura; i++)); do b+="░"; done
    echo -e "${cor}${b}${NC}"
}

resumo_recursos() {
    local pid; pid=$(pid_do_servidor)
    [[ -z "$pid" ]] && { echo -e "  ${YELLOW}(sem processo do jogo)${NC}"; return; }
    local cpu mem rss
    read -r cpu mem rss < <(ps -p "$pid" -o %cpu=,%mem=,rss= 2>/dev/null)
    [[ -z "${cpu:-}" ]] && { echo -e "  ${YELLOW}(processo saiu na leitura)${NC}"; return; }
    echo -e "  Jogo: ${BOLD}CPU ${cpu}%${NC} · ${BOLD}RAM $(( ${rss:-0} / 1024 )) MB (${mem}%)${NC} · PID ${pid}"
}

pausar() { echo ""; read -r -p "Pressione ENTER para continuar..."; }

contar() {
    local padrao="$1" arquivo="$2"
    [[ -f "$arquivo" || -L "$arquivo" ]] || { echo 0; return; }
    grep -Fc -- "$padrao" "$arquivo" 2>/dev/null | head -n1
}

contar_re() {
    local padrao="$1" arquivo="$2"
    [[ -f "$arquivo" || -L "$arquivo" ]] || { echo 0; return; }
    grep -Ec -- "$padrao" "$arquivo" 2>/dev/null | head -n1
}

linha_diag() {
    local rotulo="$1" valor="$2" cor="${3:-$NC}"
    printf "  %-34s ${cor}%s${NC}\n" "$rotulo" "$valor"
}

# ── Envio de comando ao console do jogo ─────────────────────
enviar_comando() {
    local linha="$1"
    [[ -z "$linha" ]] && return 1
    [[ -p "$IN_FIFO" ]] || return 2
    # timeout: sem leitor na outra ponta, a escrita bloquearia o painel.
    timeout 2 bash -c "echo \"\$1\" > \"\$2\"" _ "$linha" "$IN_FIFO" || return 3
    return 0
}

# ── Verificação do encerramento ─────────────────────────────
# Confere no log de UMA sessão se o encerramento salvou.
# Imprime um código e devolve 0 só quando o estado em disco é confiável.
verificar_encerramento() {
    local logf="$1"
    [[ -n "$logf" && -f "$logf" ]] || { echo "SEM_LOG"; return 2; }

    if grep -qF "Shutdown concluído" "$logf" 2>/dev/null; then
        if grep -qE "Save síncrono FALHOU|SalvarSincrono\('.*'\) IGNORADO" "$logf" 2>/dev/null; then
            echo "SAVE_FALHOU"; return 1
        fi
        if grep -qF "ABORTADO: restauração" "$logf" 2>/dev/null; then
            # Parado antes do fim da restauração: o disco JÁ é o estado certo.
            echo "RESTAURACAO_INCOMPLETA"; return 0
        fi
        echo "OK"; return 0
    fi

    echo "SEM_SHUTDOWN"; return 1
}

explicar_encerramento() {
    case "$1" in
        OK)                     ok "Save final confirmado (Shutdown concluído)." ;;
        RESTAURACAO_INCOMPLETA) warn "Parado antes do fim da restauração — o save em disco foi preservado (correto)." ;;
        SAVE_FALHOU)            err "O encerramento rodou, mas o save do MUNDO falhou. Veja o log." ;;
        SEM_SHUTDOWN)           err "NÃO há 'Shutdown concluído' no log — o processo foi morto antes do save." ;;
        SEM_LOG)                warn "Log da sessão não encontrado para conferir o save." ;;
        *)                      warn "Resultado de encerramento desconhecido: $1" ;;
    esac
}

# Espera a NOVA sessão liberar conexões. $2 = log da sessão ANTERIOR: o
# symlink current.log só é repontado quando o launcher sobe, e até lá ainda
# aponta para o log velho (que também contém "Conexões LIBERADAS").
aguardar_servidor_pronto() {
    local limite="${1:-$ESPERA_PRONTO_S}" log_anterior="${2:-}" inicio=$SECONDS logf
    while (( SECONDS - inicio < limite )); do
        esta_rodando || return 2
        logf=$(readlink -f "$CURRENT_LOG" 2>/dev/null)
        if [[ -n "$logf" && "$logf" != "$log_anterior" ]] \
           && grep -qF "Conexões LIBERADAS" "$logf" 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    return 1
}

# Backup dos saves. Íntegro só com o servidor PARADO.
fazer_backup() {
    mkdir -p "$BACKUP_DIR"
    local existentes=() d
    for d in "${SAVE_DIRS[@]}"; do
        [[ -d "$SERVER_DIR/$d" ]] && existentes+=("$d")
    done

    if (( ${#existentes[@]} == 0 )); then
        warn "Nenhuma pasta de save encontrada (esperado: ${SAVE_DIRS[*]})."
        return 1
    fi

    local arq="$BACKUP_DIR/saves_$(date '+%Y-%m-%d_%H-%M-%S').tar.gz"
    log "Compactando: ${existentes[*]}"

    # nice/ionice: se o servidor estiver no ar, o tar não disputa a main thread.
    if ! nice -n 19 ionice -c3 tar -czf "$arq" -C "$SERVER_DIR" "${existentes[@]}" 2>/dev/null; then
        err "Falha ao criar o backup."
        rm -f "$arq"
        return 1
    fi

    # Rodando como root (timer), o arquivo nasceria do root.
    chown "$USER_OWNER:$GROUP_OWNER" "$arq" 2>/dev/null

    # Mantém só os N mais recentes.
    local total
    total=$(ls -1t "$BACKUP_DIR"/saves_*.tar.gz 2>/dev/null | wc -l)
    if (( total > BACKUP_RETENTION )); then
        ls -1t "$BACKUP_DIR"/saves_*.tar.gz | tail -n +$(( BACKUP_RETENTION + 1 )) \
            | xargs -r rm -f
        log "Backups antigos removidos (mantidos $BACKUP_RETENTION)."
    fi

    ok "Backup: $arq ($(du -h "$arq" | cut -f1))"
    return 0
}

# Reinício SEGURO: para (save confirmado) → backup → sobe → espera pronto.
# Usado pelo reinício manual e pelo programado.
reiniciar_seguro() {
    local origem="$1" com_backup="${2:-1}"
    local SUDO; SUDO=$(precisa_sudo)

    local log_anterior
    log_anterior=$(readlink -f "$CURRENT_LOG" 2>/dev/null)

    log "($origem) Parando — o save final pode levar até ${STOP_WAIT_WRAPPER}s. NÃO interrompa."
    local inicio=$SECONDS
    $SUDO systemctl stop "$SERVICE_NAME"
    log "($origem) Parado em $(( SECONDS - inicio ))s."

    if esta_rodando; then
        err "($origem) O serviço ainda está ativo após o stop. Abortando o reinício."
        return 1
    fi

    local resultado
    resultado=$(verificar_encerramento "$log_anterior")
    explicar_encerramento "$resultado"

    # Backup SEMPRE com o servidor parado: arquivos estáveis e consistentes.
    # Mesmo com o save final falho, o backup guarda o último estado bom.
    if [[ "$com_backup" == "1" ]]; then
        fazer_backup || warn "($origem) Seguindo sem backup."
    fi

    log "($origem) Iniciando..."
    $SUDO systemctl start "$SERVICE_NAME"

    log "($origem) Aguardando a restauração do mundo (até $(( ESPERA_PRONTO_S / 60 )) min)..."
    if aguardar_servidor_pronto "$ESPERA_PRONTO_S" "$log_anterior"; then
        ok "($origem) Servidor pronto e aceitando jogadores ($(( SECONDS - inicio ))s no total)."
        return 0
    fi

    if esta_rodando; then
        warn "($origem) Servidor ativo, mas ainda não liberou conexões. Veja o log."
    else
        err "($origem) O servidor NÃO subiu. Veja o diagnóstico (8)."
    fi
    return 1
}

# ============================================================
#  DEPENDÊNCIAS DO SISTEMA
# ============================================================
acao_dependencias() {
    local SUDO; SUDO=$(precisa_sudo)
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a          # Ubuntu 24.04 abre prompt sem isto

    log "Atualizando índices de pacotes..."
    $SUDO apt-get update -qq || warn "apt-get update retornou erro."

    log "Aplicando upgrade (pode demorar)..."
    $SUDO apt-get -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" upgrade \
        || warn "apt-get upgrade retornou erro."

    log "Instalando dependências..."
    $SUDO apt-get install -y -qq --no-install-recommends \
        ca-certificates curl wget jq tar unzip xz-utils \
        tmux procps psmisc lsof iproute2 util-linux \
        libc6 libstdc++6 libgcc-s1 zlib1g \
        vnstat sysstat htop logrotate tzdata chrony \
        || err "Falha ao instalar dependências."

    # ── Relógio ─────────────────────────────────────────────
    # Wipe, Raid e o reinício programado são agendados por hora de
    # parede. Na EC2, o Amazon Time Sync fica no endereço de link-local
    # abaixo; fora da AWS ele não responde e o chrony usa os padrões.
    if [[ -f /etc/chrony/chrony.conf ]] \
       && ! grep -q '169.254.169.123' /etc/chrony/chrony.conf; then
        echo 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' \
            | $SUDO tee -a /etc/chrony/chrony.conf >/dev/null
        $SUDO systemctl restart chrony 2>/dev/null
        ok "Amazon Time Sync configurado no chrony."
    fi
    $SUDO timedatectl set-timezone America/Sao_Paulo 2>/dev/null

    # ── Reboot automático ───────────────────────────────────
    # Atualizar tudo bem; reiniciar a máquina sozinho no meio de um raid, não.
    echo 'Unattended-Upgrade::Automatic-Reboot "false";' \
        | $SUDO tee /etc/apt/apt.conf.d/99-decay-no-reboot >/dev/null

    $SUDO systemctl enable --now vnstat 2>/dev/null

    ok "Dependências instaladas."
    verificar_libs
}

# Não adivinhe quais bibliotecas o build precisa — pergunte a ele.
verificar_libs() {
    if [[ ! -f "$APP" ]]; then
        warn "Executável ausente ($APP) — pulei a checagem de libs."
        return
    fi
    local faltando
    faltando=$(ldd "$APP" 2>/dev/null | grep -i "not found")
    if [[ -n "$faltando" ]]; then
        err "Bibliotecas dinâmicas AUSENTES:"
        echo "$faltando" | sed 's/^/    /'
        warn "Instale os pacotes correspondentes antes de iniciar."
        return 1
    fi
    ok "Todas as dependências dinâmicas do executável estão resolvidas."
}

# ============================================================
#  SWAP / SYSCTL
# ============================================================
config_swap() {
    local SUDO; SUDO=$(precisa_sudo)

    if swapon --show 2>/dev/null | grep -q .; then
        local tam
        tam=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo)
        ok "Swap já ativo (${tam} MB) — mantendo."
        (( tam > 4096 )) && warn "Swap acima de 4 GB favorece thrashing sob pressão de GC."
        return 0
    fi

    if [[ -f "$SWAP_FILE" ]]; then
        warn "Swapfile existe mas está inativo. Reativando..."
        $SUDO chmod 600 "$SWAP_FILE"
        $SUDO swapon "$SWAP_FILE" 2>/dev/null && { ok "Swap reativado."; return 0; }
        $SUDO swapoff "$SWAP_FILE" 2>/dev/null
        $SUDO rm -f "$SWAP_FILE"
    fi

    local livre
    livre=$(df --output=avail -m "$(dirname "$SWAP_FILE")" 2>/dev/null | tail -n1 | tr -d ' ')
    if [[ -z "$livre" ]] || (( livre < SWAP_SIZE_MB + 1024 )); then
        err "Espaço insuficiente para swap de ${SWAP_SIZE_MB}MB (livre: ${livre:-?}MB)."
        return 1
    fi

    log "Criando swap de ${SWAP_SIZE_MB}MB..."
    $SUDO fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null \
        || $SUDO dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress

    $SUDO chmod 600 "$SWAP_FILE"
    $SUDO mkswap "$SWAP_FILE" >/dev/null || { err "mkswap falhou."; return 1; }
    $SUDO swapon "$SWAP_FILE" || { err "swapon falhou."; return 1; }

    grep -qF "$SWAP_FILE" /etc/fstab 2>/dev/null \
        || echo "$SWAP_FILE none swap sw 0 0" | $SUDO tee -a /etc/fstab >/dev/null

    ok "Swap de ${SWAP_SIZE_MB}MB ativo (rede de segurança contra OOM)."
}

config_sysctl() {
    local SUDO; SUDO=$(precisa_sudo)

    log "Aplicando parâmetros de kernel..."
    $SUDO tee "$SYSCTL_PATH" >/dev/null <<'EOF'
# ── Buffers de socket UDP ───────────────────────────────────
# O kcp2k PEDE 7 MB (KcpRecvBufferSize/KcpSendBufferSize). O Linux corta
# silenciosamente em net.core.rmem_max (default ~208 KB). Cortado, o
# kernel DESCARTA pacotes sob rajada, o kcp retransmite e o RTT salta.
# O teto precisa ser MAIOR que o pedido, não igual.
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=5000

# Prefere estrangular a matar por OOM. O GC do IL2CPP devolve pouco ao
# SO, então um pico transiente vira RSS permanente.
vm.swappiness=10

# IL2CPP + Newtonsoft mapeiam muita região; o default de 65530 é apertado.
vm.max_map_count=262144
EOF
    $SUDO sysctl --system >/dev/null 2>&1
    ok "sysctl aplicado ($SYSCTL_PATH)."
}

# ============================================================
#  SEGUIDOR DE LOG (tmux)
# ============================================================
run_tail() {
    trap 'kill "${tp:-}" 2>/dev/null; exit 0' SIGTERM SIGINT EXIT
    local atual="" alvo tp
    while true; do
        alvo=$(readlink -f "$CURRENT_LOG" 2>/dev/null)
        if [[ -z "$alvo" || ! -f "$alvo" ]]; then
            sleep 2; continue
        fi
        if [[ "$alvo" != "$atual" ]]; then
            [[ -n "${tp:-}" ]] && { kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null; }
            atual="$alvo"
            echo -e "\n${CYAN}── seguindo $(basename "$alvo") ──${NC}\n"
            tail -n 200 -F "$alvo" & tp=$!
        fi
        sleep 2
    done
}

# ============================================================
#  REINÍCIO PROGRAMADO
# ============================================================

# Segundos desde que o serviço do jogo ficou ativo.
uptime_servico_s() {
    local desde_us agora_s
    desde_us=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$SERVICE_NAME" 2>/dev/null)
    agora_s=$(awk '{print int($1)}' /proc/uptime)
    [[ -z "$desde_us" || "$desde_us" == "0" ]] && { echo 0; return; }
    echo $(( agora_s - desde_us / 1000000 ))
}

avisar_reinicio() {
    local min="$1"
    echo "[$(date '+%F %T')] Aviso: reinício em ${min} min."
    [[ -z "$RESTART_AVISO_CMD" ]] && return
    # shellcheck disable=SC2059
    enviar_comando "$(printf "$RESTART_AVISO_CMD" "$min")" \
        || echo "[$(date '+%F %T')] Falha ao enviar aviso pela FIFO."
}

# Modo __restart: executado pelo decay-restart.service (disparado pelo timer).
run_restart_agendado() {
    # Impede dois reinícios simultâneos (timer + manual, ou timer duplicado).
    exec 9>"$RESTART_LOCK"
    if ! flock -n 9; then
        echo "[$(date '+%F %T')] Outro reinício já está em andamento. Saindo."
        exit 0
    fi

    echo "[$(date '+%F %T')] Reinício programado iniciado."

    if ! esta_rodando; then
        echo "[$(date '+%F %T')] Servidor parado — nada a fazer."
        exit 0
    fi

    local up; up=$(uptime_servico_s)
    if (( up < RESTART_MIN_UPTIME_H * 3600 )); then
        echo "[$(date '+%F %T')] Servidor no ar há só $(( up / 60 )) min" \
             "(< ${RESTART_MIN_UPTIME_H}h). Reinício PULADO."
        exit 0
    fi

    local n=${#RESTART_AVISOS_MIN[@]} i atual proximo
    for (( i = 0; i < n; i++ )); do
        atual=${RESTART_AVISOS_MIN[$i]}
        proximo=${RESTART_AVISOS_MIN[$((i + 1))]:-0}

        avisar_reinicio "$atual"
        sleep $(( (atual - proximo) * 60 ))

        if ! esta_rodando; then
            echo "[$(date '+%F %T')] Servidor parou durante os avisos — abortando."
            exit 0
        fi
    done

    local rss_mb=0 pid
    pid=$(pid_do_servidor)
    [[ -n "$pid" ]] && rss_mb=$(( $(ps -o rss= -p "$pid" 2>/dev/null || echo 0) / 1024 ))
    echo "[$(date '+%F %T')] Reiniciando após $(( up / 3600 ))h no ar (RSS ${rss_mb} MB)."

    if reiniciar_seguro "agendado" "$RESTART_COM_BACKUP"; then
        echo "[$(date '+%F %T')] Reinício programado concluído com sucesso."
        exit 0
    fi

    echo "[$(date '+%F %T')] Reinício programado terminou COM PROBLEMAS — verifique o log."
    exit 1
}

instalar_restart_timer() {
    local SUDO; SUDO=$(precisa_sudo)

    if [[ ! "$RESTART_HORARIO" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        err "RESTART_HORARIO inválido: '$RESTART_HORARIO' (use HH:MM, ex.: 06:00)."
        return 1
    fi

    local lead=${RESTART_AVISOS_MIN[0]:-0}
    local disparo
    disparo=$(date -d "$RESTART_HORARIO $lead minutes ago" '+%H:%M' 2>/dev/null) \
        || { err "Não consegui calcular o horário de disparo."; return 1; }

    # Avisos + stop (até STOP_WAIT_SYSTEMD) + backup + subida/restauração + folga.
    local timeout_min=$(( lead + STOP_WAIT_SYSTEMD / 60 + ESPERA_PRONTO_S / 60 + 10 ))

    $SUDO tee "/etc/systemd/system/$RESTART_UNIT.service" >/dev/null <<EOF
[Unit]
Description=Decay - reinício programado (avisos + save + backup + restart)

[Service]
Type=oneshot
ExecStart=$SELF __restart
TimeoutStartSec=${timeout_min}min
EOF

    $SUDO tee "/etc/systemd/system/$RESTART_UNIT.timer" >/dev/null <<EOF
[Unit]
Description=Decay - reinício diário às $RESTART_HORARIO (dispara às $disparo para os avisos)

[Timer]
OnCalendar=*-*-* $disparo:00
AccuracySec=1s
# false: se a máquina estava desligada no horário, NÃO reinicia ao ligar.
Persistent=false

[Install]
WantedBy=timers.target
EOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now "$RESTART_UNIT.timer" >/dev/null 2>&1

    ok "Reinício diário às $RESTART_HORARIO (avisos a partir das $disparo)."
    [[ -z "$RESTART_AVISO_CMD" ]] && \
        warn "RESTART_AVISO_CMD vazio: os jogadores NÃO serão avisados no chat."
}

remover_restart_timer() {
    local SUDO; SUDO=$(precisa_sudo)
    $SUDO systemctl disable --now "$RESTART_UNIT.timer" 2>/dev/null
    $SUDO rm -f "/etc/systemd/system/$RESTART_UNIT.timer" \
                "/etc/systemd/system/$RESTART_UNIT.service"
    $SUDO systemctl daemon-reload
    ok "Reinício programado removido."
}

status_restart_timer() {
    if systemctl is-enabled --quiet "$RESTART_UNIT.timer" 2>/dev/null; then
        local prox
        prox=$(systemctl show -p NextElapseUSecRealtime --value "$RESTART_UNIT.timer" 2>/dev/null)
        echo -e "${GREEN}ATIVO${NC} · ${RESTART_HORARIO} · próximo disparo: ${prox:-?}"
    else
        echo -e "${YELLOW}DESATIVADO${NC}"
    fi
}

acao_reinicio_programado() {
    echo ""
    echo -e "  Estado: $(status_restart_timer)"
    echo ""
    echo -e "  Config (topo do script): ${BOLD}$RESTART_HORARIO${NC}" \
            "· avisos: ${RESTART_AVISOS_MIN[*]:-nenhum} min" \
            "· uptime mínimo: ${RESTART_MIN_UPTIME_H}h" \
            "· backup: $( [[ "$RESTART_COM_BACKUP" == "1" ]] && echo sim || echo não )"
    if [[ -z "$RESTART_AVISO_CMD" ]]; then
        echo -e "  Aviso no chat: ${YELLOW}desligado${NC} (RESTART_AVISO_CMD vazio)"
    else
        echo -e "  Aviso no chat: ${GREEN}$RESTART_AVISO_CMD${NC}"
    fi
    echo ""
    echo -e "    ${GREEN}i${NC}) instalar / atualizar (relê as variáveis do topo do script)"
    echo -e "    ${GREEN}t${NC}) testar AGORA (avisos + save + backup + restart)"
    echo -e "    ${GREEN}r${NC}) remover"
    echo -e "    ${GREEN}l${NC}) log das últimas execuções"
    read -r -p "  Escolha [voltar]: " op
    case "${op:-}" in
        i|I) instalar_restart_timer ;;
        t|T)
            if [[ ! -f "/etc/systemd/system/$RESTART_UNIT.service" ]]; then
                err "Instale primeiro (opção i)."
            else
                warn "Isto reinicia o servidor de verdade, com os avisos configurados."
                warn "O uptime mínimo de ${RESTART_MIN_UPTIME_H}h continua valendo."
                read -r -p "  Confirmar? [s/N]: " r
                if [[ "${r,,}" == "s" ]]; then
                    local SUDO; SUDO=$(precisa_sudo)
                    $SUDO systemctl start --no-block "$RESTART_UNIT.service"
                    ok "Disparado. Acompanhe com: journalctl -u $RESTART_UNIT -f"
                fi
            fi ;;
        r|R) remover_restart_timer ;;
        l|L) journalctl -u "$RESTART_UNIT.service" -n 40 --no-pager 2>/dev/null \
                 || warn "Sem execuções registradas." ;;
    esac
    pausar
}

# ============================================================
#  1. INSTALAR / ATUALIZAR
# ============================================================
acao_instalar() {
    local SUDO; SUDO=$(precisa_sudo)
    local estava_rodando=0
    esta_rodando && estava_rodando=1

    log "Diretório: $SERVER_DIR"
    log "Dono/grupo: $USER_OWNER:$GROUP_OWNER"

    echo ""
    read -r -p "  Rodar apt update/upgrade + instalar dependências? [S/n]: " r
    [[ "${r,,}" != "n" ]] && acao_dependencias

    $SUDO chown -R "$USER_OWNER:$GROUP_OWNER" "$SERVER_DIR"
    chmod +x "$APP" 2>/dev/null || $SUDO chmod +x "$APP"
    chmod +x "$SELF" 2>/dev/null || $SUDO chmod +x "$SELF"

    mkdir -p "$LOG_DIR" "$BACKUP_DIR"
    chmod 755 "$LOG_DIR" "$BACKUP_DIR"

    config_swap
    config_sysctl

    # ── MemoryMax dimensionado pela máquina ─────────────────
    # Sem MemoryHigh: ao ultrapassá-lo o cgroup entra em RECLAIM AGRESSIVO
    # e o kernel despeja páginas do processo para o swap — thrashing criado
    # por configuração. MemoryMax é só um teto de segurança.
    local MEM_TOTAL_MB MEM_MAX_MB
    MEM_TOTAL_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
    MEM_MAX_MB=$(( MEM_TOTAL_MB * 85 / 100 ))

    log "Instalando unit do systemd (MemoryMax=${MEM_MAX_MB}M de ${MEM_TOTAL_MB}M)..."
    $SUDO tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=Decay Dedicated Server
After=network-online.target
Wants=network-online.target

# ⚠️ StartLimit* pertence a [Unit], NÃO a [Service]. Na seção errada o
# systemd IGNORA as duas e um bug de startup vira crash loop infinito.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$USER_OWNER
Group=$GROUP_OWNER
WorkingDirectory=$SERVER_DIR
ExecStart=$SELF __run

Restart=always
RestartSec=10

# 'shutdown' no console sai com $EXIT_DESLIGAR: desliga de verdade, sem
# reinício automático. 'stop' sai com 0 e o Restart=always sobe de novo.
SuccessExitStatus=$EXIT_DESLIGAR
RestartPreventExitStatus=$EXIT_DESLIGAR

# O SIGTERM vai SÓ para o wrapper (mixed). O wrapper pede ao jogo para
# salvar e sair pelo console, e só usa SIGTERM/SIGKILL no jogo se ele
# não responder. TimeoutStopSec > o total do wrapper, senão o systemd
# mata no meio da espera e o save de encerramento se perde.
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=$STOP_WAIT_SYSTEMD

MemoryAccounting=yes
MemoryMax=${MEM_MAX_MB}M
OOMScoreAdjust=-500

LimitNOFILE=65535

# O Unity escreve o log direto no arquivo (-logFile). O journald recebe
# só as linhas do wrapper.
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

    ok "Unit instalada (TimeoutStopSec=${STOP_WAIT_SYSTEMD}s, wrapper ${STOP_WAIT_WRAPPER}s," \
       "shutdown=exit $EXIT_DESLIGAR sem reinício)."

    echo ""
    read -r -p "  Configurar o reinício diário programado ($RESTART_HORARIO)? [S/n]: " r
    [[ "${r,,}" != "n" ]] && instalar_restart_timer

    ok "Instalação concluída."
    echo ""
    verificar_ip_publico

    if (( estava_rodando )); then
        warn "O serviço está rodando com a unit ANTIGA."
        warn "O novo encerramento seguro só vale depois de reiniciar."
        read -r -p "  Reiniciar agora (com save, backup e espera)? [s/N]: " r
        [[ "${r,,}" == "s" ]] && reiniciar_seguro "instalação" 1
    fi
    pausar
}

# ============================================================
#  2-4. CONTROLE
# ============================================================
acao_iniciar() {
    if esta_rodando; then
        warn "Já está rodando."
        pausar; return
    fi

    local SUDO; SUDO=$(precisa_sudo)
    local log_anterior
    log_anterior=$(readlink -f "$CURRENT_LOG" 2>/dev/null)

    $SUDO systemctl start "$SERVICE_NAME"
    sleep 2
    if ! esta_rodando; then
        err "Falhou — veja o diagnóstico (8)."
        pausar; return
    fi

    ok "Servidor iniciado."
    read -r -p "  Aguardar a restauração do mundo terminar? [S/n]: " r
    if [[ "${r,,}" != "n" ]]; then
        log "Aguardando 'Conexões LIBERADAS' (até $(( ESPERA_PRONTO_S / 60 )) min)..."
        if aguardar_servidor_pronto "$ESPERA_PRONTO_S" "$log_anterior"; then
            ok "Servidor pronto e aceitando jogadores."
        else
            warn "Ainda não liberou conexões. Acompanhe pelo console (5)."
        fi
    fi
    pausar
}

acao_parar() {
    if ! esta_rodando; then
        warn "Não está rodando."
        pausar; return
    fi
    local SUDO; SUDO=$(precisa_sudo)
    local log_anterior
    log_anterior=$(readlink -f "$CURRENT_LOG" 2>/dev/null)

    log "Parando... o save final pode levar até ${STOP_WAIT_WRAPPER}s. NÃO interrompa."
    local INICIO=$SECONDS
    $SUDO systemctl stop "$SERVICE_NAME"

    if esta_rodando; then
        err "Ainda rodando?"
    else
        ok "Servidor parado em $(( SECONDS - INICIO ))s."
    fi

    explicar_encerramento "$(verificar_encerramento "$log_anterior")"

    if grep -qF "SUPRIMIDO — wipe em andamento" "$log_anterior" 2>/dev/null; then
        warn "Saves foram SUPRIMIDOS por wipe em andamento nesta sessão."
    fi
    pausar
}

acao_reiniciar() {
    if esta_rodando; then
        warn "Jogadores conectados serão desconectados."
        warn "O save final pode levar até ${STOP_WAIT_WRAPPER}s."
        read -r -p "  Confirmar reinício? [s/N]: " r
        [[ "${r,,}" != "s" ]] && { log "Cancelado."; pausar; return; }

        local com_backup=1
        read -r -p "  Fazer backup dos saves entre a parada e a subida? [S/n]: " b
        [[ "${b,,}" == "n" ]] && com_backup=0

        # Mesmo lock do reinício programado: não roda os dois juntos.
        exec 9>"$RESTART_LOCK"
        if ! flock -n 9; then
            err "Um reinício programado está em andamento. Aguarde."
            exec 9>&-
            pausar; return
        fi

        reiniciar_seguro "manual" "$com_backup"
        exec 9>&-
    else
        local SUDO; SUDO=$(precisa_sudo)
        local log_anterior
        log_anterior=$(readlink -f "$CURRENT_LOG" 2>/dev/null)
        $SUDO systemctl start "$SERVICE_NAME"
        if aguardar_servidor_pronto "$ESPERA_PRONTO_S" "$log_anterior"; then
            ok "Servidor pronto."
        else
            warn "Servidor iniciado; acompanhe a restauração pelo console (5)."
        fi
    fi
    pausar
}

# ============================================================
#  5. CONSOLE + LOGS
# ============================================================
run_prompt() {
    echo -e "${BOLD}Console do servidor Decay${NC}"
    echo -e "Jogo:      ${GREEN}adminset Joao true${NC} · ${GREEN}players${NC}"
    echo -e "Servidor:  ${GREEN}status${NC} · ${GREEN}save${NC} · ${GREEN}say <texto>${NC}" \
            "· ${GREEN}stop [s]${NC} (reinicia) · ${GREEN}shutdown [s]${NC} (desliga)"
    echo -e "Sair do painel: ${YELLOW}Ctrl+B${NC} depois ${YELLOW}D${NC} (servidor segue rodando)."
    echo ""
    while true; do
        read -r -p "decay> " linha || break
        [[ -z "$linha" ]] && continue
        if [[ "$linha" == "sair" || "$linha" == "exit" ]]; then
            echo "Use Ctrl+B depois D para fechar o painel."
            continue
        fi
        enviar_comando "$linha"
        case $? in
            0) echo -e "${CYAN}→ enviado:${NC} $linha" ;;
            2) err "FIFO ausente — o servidor está rodando?" ;;
            3) err "Escrita na FIFO expirou — servidor travado ou sem leitor." ;;
        esac
    done
}

# Fallback sem tmux: só envia comandos (logs ficam por conta do arquivo).
console_simples() {
    warn "tmux ausente — modo somente-comandos."
    echo -e "Para ver os logs, abra outro terminal: ${GREEN}tail -F $CURRENT_LOG${NC}"
    echo ""
    trap 'echo; return' SIGINT
    while true; do
        read -r -p "decay> " linha || break
        [[ "$linha" == "sair" || "$linha" == "exit" ]] && break
        [[ -z "$linha" ]] && continue
        enviar_comando "$linha" && echo -e "${CYAN}→ enviado:${NC} $linha" || err "Falha no envio."
    done
    trap - SIGINT
}

acao_console() {
    if ! esta_rodando; then
        warn "Inicie o servidor antes."
        pausar; return
    fi
    if [[ ! -p "$IN_FIFO" ]]; then
        err "FIFO não encontrada ($IN_FIFO). Aguarde 1-2s após o start."
        pausar; return
    fi

    # A FIFO é criada com -m 660: só o dono e o grupo escrevem.
    if [[ ! -w "$IN_FIFO" ]]; then
        err "Sem permissão de escrita na FIFO."
        warn "O serviço roda como '$USER_OWNER' e você é '$(id -un)'."
        warn "Use:  sudo -u $USER_OWNER $SELF"
        pausar; return
    fi

    if ! command -v tmux >/dev/null 2>&1; then
        console_simples
        pausar; return
    fi

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        read -r -p "  Sessão existente. [a]nexar ou [r]ecriar? [a]: " s
        if [[ "${s,,}" == "r" ]]; then
            tmux kill-session -t "$TMUX_SESSION" 2>/dev/null
        else
            tmux attach -t "$TMUX_SESSION"
            return
        fi
    fi

    log "Abrindo console + logs. Ctrl+B depois D para desanexar."
    sleep 1

    # __tail reabre o arquivo quando o symlink current.log é repontado.
    tmux new-session -d -s "$TMUX_SESSION" -n decay "'$SELF' __tail"
    tmux split-window -v -t "$TMUX_SESSION" "'$SELF' __prompt"
    tmux resize-pane -t "$TMUX_SESSION".0 -y 70%
    tmux select-pane -t "$TMUX_SESSION".1
    tmux attach -t "$TMUX_SESSION"
}

# ============================================================
#  6. STATUS & MONITOR
# ============================================================
uso_cpu_total() {
    local a b idle_a idle_b total_a total_b v
    read -ra a < <(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
    idle_a=${a[3]}; total_a=0
    for v in "${a[@]}"; do total_a=$(( total_a + v )); done
    sleep 1
    read -ra b < <(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat)
    idle_b=${b[3]}; total_b=0
    for v in "${b[@]}"; do total_b=$(( total_b + v )); done
    local dt=$(( total_b - total_a )) di=$(( idle_b - idle_a ))
    local st=$(( ${b[7]:-0} - ${a[7]:-0} ))
    local pct=0 steal=0
    (( dt > 0 )) && pct=$(( (dt - di) * 100 / dt ))
    (( dt > 0 )) && steal=$(( st * 100 / dt ))
    echo "$pct $steal"
}

# Taxa de rede em KB/s.
rede_taxa() {
    local r1 t1 r2 t2
    read -r r1 t1 < <(awk -F'[: ]+' 'NR>2 && $2!="lo" {r+=$3; t+=$11} END{print r, t}' /proc/net/dev)
    sleep 1
    read -r r2 t2 < <(awk -F'[: ]+' 'NR>2 && $2!="lo" {r+=$3; t+=$11} END{print r, t}' /proc/net/dev)
    echo "↓ $(( (r2 - r1) / 1024 )) KB/s · ↑ $(( (t2 - t1) / 1024 )) KB/s"
}

render_monitor() {
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║       STATUS & MONITOR · DECAY              ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo -e "  ${CYAN}$(date '+%F %T')${NC}  ·  $(status_curto)"
    echo ""

    echo -e "${BOLD}── Processo do jogo ─────────────────────────${NC}"
    local pid; pid=$(pid_do_servidor)
    if [[ -z "$pid" ]]; then
        warn "Nenhum processo do jogo em execução."
    else
        local cpu mem rss nlwp etime
        read -r cpu mem rss nlwp etime < <(ps -p "$pid" -o %cpu=,%mem=,rss=,nlwp=,etime= 2>/dev/null)
        if [[ -z "${cpu:-}" ]]; then
            warn "Processo saiu durante a leitura."
        else
            printf "  PID............: %s\n" "$pid"
            printf "  Uptime.........: %s\n" "${etime// /}"
            printf "  Threads........: %s\n" "$nlwp"
            printf "  CPU (processo).: %5s%%  %b\n" "$cpu" "$(barra_pct "$cpu")"
            printf "  RAM (RSS)......: %s MB (%s%%)  %b\n" \
                "$(( ${rss:-0} / 1024 ))" "$mem" "$(barra_pct "$mem")"

            # Distância até o MemoryMax da unit: é o que define o OOM.
            local mmax
            mmax=$(systemctl show -p MemoryMax --value "$SERVICE_NAME" 2>/dev/null)
            if [[ "$mmax" =~ ^[0-9]+$ ]] && (( mmax > 0 )); then
                local pmax=$(( ${rss:-0} * 1024 * 100 / mmax ))
                printf "  RSS / MemoryMax: %s%% de %s MB  %b\n" \
                    "$pmax" "$(( mmax / 1024 / 1024 ))" "$(barra_pct "$pmax")"
                (( pmax >= 85 )) && echo -e "  ${RED}Perto do MemoryMax: risco de OOM kill.${NC}"
            fi

            local sw
            sw=$(awk '/^VmSwap:/{print int($2/1024)}' "/proc/$pid/status" 2>/dev/null)
            if [[ -n "${sw:-}" ]]; then
                if (( sw > 200 )); then
                    printf "  RAM em SWAP....: ${RED}%s MB${NC}  ← paginação do heap, causa de stall\n" "$sw"
                else
                    printf "  RAM em SWAP....: %s MB\n" "$sw"
                fi
            fi

            local tpct tname
            read -r tpct tname _ < <(thread_mais_quente "$pid")
            printf "  Thread + quente: %5s%% (%s)  %b\n" "$tpct" "$tname" "$(barra_pct "$tpct")"
            if (( tpct >= 90 )); then
                echo -e "  ${RED}Main thread saturada: mais vCPU NÃO ajuda.${NC}"
                echo -e "  ${RED}Só core mais rápido ou menos trabalho por frame.${NC}"
            fi
            echo -e "  ${CYAN}RSS deve estabilizar num platô. Subida contínua = leak.${NC}"
        fi
    fi
    printf "  Reinício diário: %b\n" "$(status_restart_timer)"
    echo ""

    echo -e "${BOLD}── Máquina ──────────────────────────────────${NC}"
    printf "  Núcleos........: %s\n" "$(nproc 2>/dev/null || echo '?')"
    printf "  Load (1/5/15m).: %s\n" "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"

    local c st
    read -r c st < <(uso_cpu_total)
    printf "  CPU total......: %5s%%  %b\n" "$c" "$(barra_pct "$c")"
    if (( st >= 5 )); then
        printf "  Steal time.....: ${RED}%s%%${NC}  ← o host está sobrevendido\n" "$st"
    else
        printf "  Steal time.....: %s%%\n" "$st"
    fi

    local mt ma stot sfree
    mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    stot=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    sfree=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)

    local mu=$(( mt - ma )) mp=0
    (( mt > 0 )) && mp=$(( mu * 100 / mt ))
    printf "  RAM............: %s / %s MB (%s%%)  %b\n" \
        "$(( mu / 1024 ))" "$(( mt / 1024 ))" "$mp" "$(barra_pct "$mp")"

    if (( stot > 0 )); then
        local su=$(( stot - sfree )) sp=$(( (stot - sfree) * 100 / stot ))
        printf "  Swap...........: %s / %s MB (%s%%)  %b\n" \
            "$(( su / 1024 ))" "$(( stot / 1024 ))" "$sp" "$(barra_pct "$sp")"
        (( sp >= 90 )) && echo -e "  ${RED}Swap quase cheio: direct reclaim → stall → todos caem juntos.${NC}"
    else
        printf "  Swap...........: ${RED}DESATIVADO${NC} (risco de OOM sem save)\n"
    fi

    if [[ -r /proc/pressure/io ]]; then
        printf "  Pressão I/O....: %s\n" "$(awk '/^some/{print $2, $3}' /proc/pressure/io)"
    fi
    if [[ -r /proc/pressure/memory ]]; then
        printf "  Pressão memória: %s\n" "$(awk '/^some/{print $2, $3}' /proc/pressure/memory)"
    fi

    local d; d=$(df -h --output=used,size,pcent "$SERVER_DIR" 2>/dev/null | tail -n1)
    if [[ -n "$d" ]]; then
        local du ds dp; read -r du ds dp <<< "$d"
        printf "  Disco..........: %s / %s (%s)  %b\n" "$du" "$ds" "$dp" "$(barra_pct "${dp%\%}")"
    fi
    printf "  Logs...........: %s\n" "$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1 || echo '?')"
    printf "  Backups........: %s\n" "$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo '?')"
    printf "  Rede...........: %s\n" "$(rede_taxa)"

    # Descartes de UDP por buffer cheio: o que importa é se está SUBINDO.
    local rcvbuf
    rcvbuf=$(awk '/^Udp:/{n++} n==2 && /^Udp:/{print $6; exit}' /proc/net/snmp 2>/dev/null)
    [[ -n "${rcvbuf:-}" ]] && printf "  UDP RcvbufErrors: %s (desde o boot; compare entre leituras)\n" "$rcvbuf"

    if command -v vnstat >/dev/null 2>&1; then
        local tx
        tx=$(vnstat --oneline 2>/dev/null | cut -d';' -f10)
        [[ -n "${tx:-}" ]] && printf "  Egress no mês..: %s\n" "$tx"
    fi
}

acao_monitor() {
    echo ""
    echo -e "    ${GREEN}l${NC}) ao vivo (Ctrl+C para voltar)"
    echo -e "    ${GREEN}s${NC}) snapshot"
    echo -e "    ${GREEN}u${NC}) systemctl status (unit)"
    read -r -p "  Escolha [s]: " modo
    case "${modo:-s}" in
        l|L)
            trap 'echo; return' SIGINT
            while true; do clear; render_monitor
                echo -e "\n  ${YELLOW}Ctrl+C para voltar.${NC}"; done
            trap - SIGINT ;;
        u|U)
            echo ""; systemctl status "$SERVICE_NAME" --no-pager -n 30 2>/dev/null \
                || warn "Serviço não instalado."; pausar ;;
        *) echo ""; render_monitor; pausar ;;
    esac
}

# ============================================================
#  7. BACKUP DOS SAVES
# ============================================================
acao_backup() {
    if esta_rodando; then
        warn "Servidor RODANDO: o tar pode pegar um save no meio da escrita."
        echo -e "  O backup ${BOLD}íntegro${NC} acontece sozinho no reinício (opção 4 ou o programado),"
        echo -e "  com o servidor parado entre o save final e a subida."
        echo -e "  Alternativa: a pasta ${GREEN}WorldSaves/Rotacao/${NC} guarda saves já promovidos."
        read -r -p "  Continuar mesmo assim? [s/N]: " r
        [[ "${r,,}" != "s" ]] && { log "Cancelado."; pausar; return; }
    fi

    fazer_backup

    echo ""
    echo -e "  Restaurar manualmente (${BOLD}com o servidor PARADO${NC}):"
    echo -e "    ${GREEN}tar -xzf <arquivo> -C $SERVER_DIR${NC}"
    pausar
}

# ============================================================
#  8. DIAGNÓSTICO
# ============================================================
acao_diagnostico() {
    clear
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║          DIAGNÓSTICO · DECAY                ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════╝${NC}"

    # ── Arquivos de save ────────────────────────────────────
    echo -e "\n${BOLD}── Arquivos de save ─────────────────────────${NC}"
    local ws="$SERVER_DIR/WorldSaves/world_transforms.json"
    if [[ -f "$ws" ]]; then
        linha_diag "world_transforms.json" \
            "$(du -h "$ws" | cut -f1), $(date -r "$ws" '+%F %H:%M:%S')"
    else
        linha_diag "world_transforms.json" "AUSENTE" "$RED"
    fi

    [[ -f "$ws.backup" ]] \
        && linha_diag "backup" "$(du -h "$ws.backup" | cut -f1), $(date -r "$ws.backup" '+%F %H:%M')" \
        || linha_diag "backup" "ausente" "$YELLOW"

    local rot
    rot=$(find "$SERVER_DIR/WorldSaves/Rotacao" -type f 2>/dev/null | wc -l)
    linha_diag "Arquivos na rotação" "$rot" "$( ((rot>0)) && echo "$GREEN" || echo "$YELLOW")"

    local tmps
    tmps=$(find "$SERVER_DIR/WorldSaves" "$SERVER_DIR/PlayerSaves" -name "*.tmp" 2>/dev/null | wc -l)
    (( tmps > 0 )) \
        && linha_diag ".tmp órfãos (crash na escrita)" "$tmps" "$RED" \
        || linha_diag ".tmp órfãos" "0"

    if [[ -d "$SERVER_DIR/PlayerSaves" ]]; then
        linha_diag "Saves de player" \
            "$(find "$SERVER_DIR/PlayerSaves" -name '*.json' 2>/dev/null | wc -l)"
        local corr
        corr=$(find "$SERVER_DIR/PlayerSaves" -name '*.corrupted_*' 2>/dev/null | wc -l)
        (( corr > 0 )) \
            && linha_diag "Saves CORROMPIDOS" "$corr" "$RED" \
            || linha_diag "Saves corrompidos" "0"
    fi

    local ultimo_bkp
    ultimo_bkp=$(ls -1t "$BACKUP_DIR"/saves_*.tar.gz 2>/dev/null | head -n1)
    if [[ -n "$ultimo_bkp" ]]; then
        linha_diag "Último backup" "$(basename "$ultimo_bkp") ($(du -h "$ultimo_bkp" | cut -f1))"
    else
        linha_diag "Último backup" "nenhum" "$YELLOW"
    fi

    # ── Encerramentos recentes ──────────────────────────────
    echo -e "\n${BOLD}── Encerramentos recentes ───────────────────${NC}"

    # Sessão ANTERIOR: é ela que diz se o último encerramento salvou.
    local log_ant
    log_ant=$(ls -1t "$LOG_DIR"/server_*.log 2>/dev/null | sed -n 2p)
    if [[ -n "$log_ant" ]]; then
        local res
        res=$(verificar_encerramento "$log_ant")
        local cor=$GREEN
        [[ "$res" == "SAVE_FALHOU" || "$res" == "SEM_SHUTDOWN" ]] && cor=$RED
        linha_diag "Último encerramento" "$res ($(basename "$log_ant"))" "$cor"
    else
        linha_diag "Último encerramento" "sem sessão anterior" "$YELLOW"
    fi

    local termos kills
    termos=$(journalctl -u "$SERVICE_NAME" --since "-7 days" --no-pager 2>/dev/null \
            | grep -c "SIGTERM (plano B)")
    linha_diag "SIGTERM de fallback (7 dias)" "${termos:-0}" \
        "$( (( ${termos:-0} > 0 )) && echo "$YELLOW" || echo "$GREEN")"
    kills=$(journalctl -u "$SERVICE_NAME" --since "-7 days" --no-pager 2>/dev/null \
            | grep -c "SIGKILL — o save final")
    linha_diag "SIGKILL no encerramento (7 dias)" "${kills:-0}" \
        "$( (( ${kills:-0} > 0 )) && echo "$RED" || echo "$GREEN")"
    local ooms
    ooms=$(dmesg -T 2>/dev/null | grep -c "Killed process.*$APP_NAME")
    linha_diag "OOM kills (desde o boot)" "${ooms:-0}" \
        "$( (( ${ooms:-0} > 0 )) && echo "$RED" || echo "$GREEN")"

    local rest_ok rest_falha
    rest_ok=$(journalctl -u "$RESTART_UNIT.service" --since "-7 days" --no-pager 2>/dev/null \
            | grep -c "concluído com sucesso")
    rest_falha=$(journalctl -u "$RESTART_UNIT.service" --since "-7 days" --no-pager 2>/dev/null \
            | grep -c "COM PROBLEMAS")
    linha_diag "Reinícios programados ok / falha" "${rest_ok:-0} / ${rest_falha:-0}" \
        "$( (( ${rest_falha:-0} > 0 )) && echo "$RED" || echo "$GREEN")"

    # ── Config efetiva ──────────────────────────────────────
    if tem_jq && [[ -f "$CONFIG_JSON" ]]; then
        echo -e "\n${BOLD}── Config efetiva (server_config.json) ──────${NC}"
        linha_diag "Nome / Porta / Time" \
            "$(cfg .NomeDoServidor) · $(cfg .Porta) · $(cfg .LimiteDeTime)"
        linha_diag "MaxPlayers" "$(cfg .MaxPlayers)"
        linha_diag "SendRate / TargetFrameRate" \
            "$(cfg .Rede.SendRate) / $(cfg .Rede.TargetFrameRate)"
        linha_diag "KcpTimeout" "$(cfg .Rede.KcpTimeout) ms"
        linha_diag "VisRange / CellHeight" \
            "$(cfg .Interesse.VisRange) / $(cfg .Interesse.CellHeight)"
        linha_diag "Save: orçamento / intervalo" \
            "$(cfg .Save.OrcamentoMsPorFrame) ms / $(cfg .Save.IntervaloMundoSegundos) s"

        local inc; inc=$(cfg .Save.SaveIncremental)
        linha_diag "SaveIncremental" "$inc" \
            "$( [[ "$inc" == "true" ]] && echo "$YELLOW" || echo "$NC")"
        [[ "$inc" == "true" ]] && \
            warn "  Só é seguro se toda mutação chama NotificarMutacao/NotificarMutacaoLeve."

        local wh wm
        wh=$(cfg .Wipe.Habilitado); wm=$(cfg .Wipe.ModoSimulacao)
        if [[ "$wh" == "true" && "$wm" == "true" ]]; then
            linha_diag "Wipe" "habilitado MAS em ModoSimulacao" "$RED"
            warn "  O wipe só avisa e loga — NÃO apaga nada. O mundo cresce sem parar."
        else
            linha_diag "Wipe" "hab=$wh · simulacao=$wm · a cada $(cfg .Wipe.IntervaloDias)d $(cfg .Wipe.Horario)"
        fi

        linha_diag "Raid" "hab=$(cfg .Raid.Habilitado) · $(cfg .Raid.Inicio) por $(cfg .Raid.Duracao)"
    fi

    # ── Marcadores no log ───────────────────────────────────
    echo -e "\n${BOLD}── Log da sessão atual ──────────────────────${NC}"
    if [[ ! -e "$CURRENT_LOG" ]]; then
        warn "Sem log de sessão ($CURRENT_LOG). O servidor já rodou com este script?"
        pausar; return
    fi
    linha_diag "Arquivo" "$(readlink -f "$CURRENT_LOG" | xargs basename)"

    local n ms obj wall players heap

    echo -e "\n  ${BOLD}Inicialização${NC}"
    if grep -qF "Conexões LIBERADAS" "$CURRENT_LOG" 2>/dev/null; then
        linha_diag "Restauração do mundo" \
            "$(grep -oP 'Restauração concluída em \K[0-9.]+s' "$CURRENT_LOG" | tail -1) — conexões liberadas" "$GREEN"
    else
        linha_diag "Restauração do mundo" "em andamento (conexões bloqueadas)" "$YELLOW"
    fi
    n=$(contar "stdin ENCERRADO" "$CURRENT_LOG")
    linha_diag "Console (stdin) funcional" \
        "$( ((n>0)) && echo "NÃO — encerramento seguro indisponível" || echo "sim")" \
        "$( ((n>0)) && echo "$RED" || echo "$GREEN")"

    echo -e "\n  ${BOLD}Saúde do save${NC}"
    n=$(contar_re '\[WorldSave\] [0-9]+ objetos' "$CURRENT_LOG")
    linha_diag "Saves de mundo concluídos" "$n" "$( ((n>0)) && echo "$GREEN" || echo "$YELLOW")"

    ms=$(grep -oP 'main thread \K[0-9]+(?=ms)' "$CURRENT_LOG" 2>/dev/null | tail -1)
    obj=$(grep -oP '\[WorldSave\] \K[0-9]+(?= objetos)' "$CURRENT_LOG" 2>/dev/null | tail -1)
    wall=$(grep -oP 'em \K[0-9]+(?=ms reais)' "$CURRENT_LOG" 2>/dev/null | tail -1)
    heap=$(grep -oP 'HEAPMB = \K[0-9]+' "$CURRENT_LOG" 2>/dev/null | tail -1)

    linha_diag "Último save: objetos" "${obj:-?}" "$CYAN"
    linha_diag "Último save: main thread" "${ms:-?} ms" \
        "$( [[ -n "${ms:-}" && "${ms:-0}" -gt 2000 ]] && echo "$RED" || echo "$GREEN")"
    linha_diag "Último save: wall clock" "${wall:-?} ms" "$CYAN"
    linha_diag "Heap managed (HEAPMB)" "${heap:-?} MB" "$CYAN"

    if [[ -n "${ms:-}" && -n "${obj:-}" && "${obj:-0}" -gt 0 ]]; then
        linha_diag "Custo por objeto" \
            "$(awk -v a="$ms" -v b="$obj" 'BEGIN{printf "%.2f ms", a/b}')" "$CYAN"
        echo -e "  ${CYAN}Acima de ~0,30 ms/objeto costuma ser paginação, não reflexão.${NC}"
    fi

    n=$(contar "Save RECUSADO" "$CURRENT_LOG")
    linha_diag "Saves recusados (queda de contagem)" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "Salvar() adiado" "$CURRENT_LOG")
    linha_diag "Saves adiados (restauração)" "$n" "$( ((n>0)) && echo "$YELLOW" || echo "$GREEN")"
    n=$(contar "Salvar() ignorado" "$CURRENT_LOG")
    linha_diag "Saves ignorados (ciclo anterior)" "$n" "$( ((n>0)) && echo "$YELLOW" || echo "$GREEN")"
    n=$(contar "Restauração TRAVADA" "$CURRENT_LOG")
    linha_diag "Restauração travada" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "Save principal suspeito" "$CURRENT_LOG")
    linha_diag "Save principal suspeito" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "Verificação FALHOU" "$CURRENT_LOG")
    linha_diag "Verificações de escrita falhas" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "Escrita em background falhou" "$CURRENT_LOG")
    linha_diag "Escritas em background falhas" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "Captura falhou em" "$CURRENT_LOG")
    linha_diag "Falhas de captura de objeto" "$n" "$( ((n>0)) && echo "$YELLOW" || echo "$GREEN")"

    echo -e "\n  ${BOLD}Interest Management${NC}"
    local aoi
    aoi=$(grep -E '^\[AOI\] conns=' "$CURRENT_LOG" 2>/dev/null | tail -1)
    if [[ -n "$aoi" ]]; then
        linha_diag "Pares obj×observador" "$(grep -oP 'pares=\K[0-9]+' <<< "$aoi")" "$CYAN"
        linha_diag "Observados por conexão (média)" "$(grep -oP 'média=\K[0-9]+' <<< "$aoi")" "$CYAN"
        linha_diag "visRange em uso" "$(grep -oP 'visRange=\K[0-9]+' <<< "$aoi")" "$CYAN"
        linha_diag "Pior frame do AOI" "$(grep -oP 'piorFrameAOI=\K[0-9.]+' <<< "$aoi") ms" "$CYAN"
    else
        linha_diag "Linhas [AOI]" "nenhuma (LogDeDiagnostico desligado?)" "$YELLOW"
    fi

    local join
    join=$(grep -E '^\[Join\]' "$CURRENT_LOG" 2>/dev/null | tail -1)
    if [[ -n "$join" ]]; then
        linha_diag "Última entrada de jogador" \
            "$(grep -oP 'AddPlayerForConnection \K[0-9.]+ ms' <<< "$join") · visíveis=$(grep -oP 'visíveis=\K[0-9]+' <<< "$join")" "$CYAN"
    fi

    echo -e "\n  ${BOLD}Corpo duplicado / sessão${NC}"
    n=$(contar "ainda está viva" "$CURRENT_LOG")
    linha_diag "Conexões fantasma derrubadas" "$n" "$CYAN"
    n=$(contar "NÃO criado" "$CURRENT_LOG")
    linha_diag "Corpos recusados (esperado > 0)" "$n" "$CYAN"
    n=$(contar "ÓRFÃO(S)" "$CURRENT_LOG")
    linha_diag "Corpos órfãos destruídos" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "fantasmas descartados" "$CURRENT_LOG")
    linha_diag "Ciclos de restauração de corpos" "$n" "$CYAN"

    echo -e "\n  ${BOLD}Integridade de dados${NC}"
    n=$(contar "JSON corrompido" "$CURRENT_LOG")
    linha_diag "JSON corrompido" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "marcadas como órfãs suspeitas" "$CURRENT_LOG")
    linha_diag "Ciclos com peças órfãs" "$n" "$( ((n>0)) && echo "$YELLOW" || echo "$GREEN")"
    n=$(contar "worldObjectId DUPLICADO" "$CURRENT_LOG")
    linha_diag "worldObjectId duplicado" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "não registrado" "$CURRENT_LOG")
    linha_diag "Prefabs ausentes (assetId)" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "REVERTIDA" "$CURRENT_LOG")
    linha_diag "Transferências de loot revertidas" "$n" "$( ((n>0)) && echo "$YELLOW" || echo "$GREEN")"
    n=$(contar "não existe mais no servidor" "$CURRENT_LOG")
    linha_diag "Playtime: conexões órfãs" "$n" "$( ((n>0)) && echo "$YELLOW" || echo "$GREEN")"

    echo -e "\n  ${BOLD}Configuração${NC}"
    n=$(contar "FALHA ao ler" "$CURRENT_LOG")
    if (( n > 0 )); then
        linha_diag "FALHA ao ler server_config.json" "$n" "$RED"
        err "  O servidor subiu com a config PADRÃO: porta, MaxPlayers e ban list ERRADOS."
    else
        linha_diag "Leitura do server_config.json" "ok" "$GREEN"
    fi
    n=$(contar "SUPRIMIDO — wipe em andamento" "$CURRENT_LOG")
    linha_diag "Saves suprimidos por wipe" "$n" "$( ((n>0)) && echo "$YELLOW" || echo "$GREEN")"

    echo -e "\n  ${BOLD}Rede${NC}"
    players=$(grep -oP '\[AutoSave\] \K[0-9]+(?=/)' "$CURRENT_LOG" 2>/dev/null | tail -1)
    linha_diag "Players no último autosave" "${players:-?}" "$CYAN"
    n=$(contar "Connection timed out" "$CURRENT_LOG")
    linha_diag "Timeouts de conexão (kcp)" "$n" "$( ((n>5)) && echo "$YELLOW" || echo "$GREEN")"
    n=$(contar "because of exception" "$CURRENT_LOG")
    linha_diag "Disconnects por exceção" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "NullReferenceException" "$CURRENT_LOG")
    linha_diag "NullReferenceException" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"

    echo -e "\n${BOLD}── Últimos saves de mundo ───────────────────${NC}"
    grep -E '\[WorldSave\] [0-9]+ objetos' "$CURRENT_LOG" 2>/dev/null | tail -n 5 \
        | cut -c1-140 | sed 's/^/  /' || echo "  (nenhum ainda)"

    echo -e "\n${BOLD}── Últimos erros ────────────────────────────${NC}"
    grep -E "(🔴|ERRO|Error|Exception|RECUSADO|TRAVADA|FALHOU|ÓRFÃO)" \
        "$CURRENT_LOG" 2>/dev/null | tail -n 8 | cut -c1-140 | sed 's/^/  /' \
        || echo "  (nenhum)"

    pausar
}

# ============================================================
#  9. VERIFICAR AMBIENTE
# ============================================================

# Confere se o IPDoServidor do config bate com o IP público real.
verificar_ip_publico() {
    local token ip_real="" ip_cfg
    token=$(curl -s --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
    if [[ -n "$token" ]]; then
        ip_real=$(curl -s --max-time 2 -H "X-aws-ec2-metadata-token: $token" \
                  http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
    fi

    if [[ -z "${ip_real:-}" ]]; then
        ip_real=$(curl -s --max-time 4 https://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n')
        [[ -n "$ip_real" ]] && log "IP público (via checkip): $ip_real"
    fi

    [[ -z "${ip_real:-}" ]] && { warn "Não consegui descobrir o IP público."; return; }

    ip_cfg=$(cfg .IPDoServidor)
    if [[ -z "$ip_cfg" ]]; then
        warn "Não consegui ler IPDoServidor (jq instalado? header /* */ presente?)."
        log  "IP público real: $ip_real"
        return
    fi

    if [[ "$ip_real" != "$ip_cfg" ]]; then
        err "IPDoServidor no config: $ip_cfg"
        err "IP público real......: $ip_real"
        warn "Os clientes não vão conseguir conectar. Corrija o config e reinicie."
    else
        ok "IPDoServidor confere com o IP público ($ip_real)."
    fi
}

acao_ambiente() {
    clear
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║        VERIFICAÇÃO DE AMBIENTE              ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════╝${NC}"

    echo -e "\n${BOLD}── Executável ───────────────────────────────${NC}"
    if [[ -f "$APP" ]]; then
        linha_diag "Binário" "$(du -h "$APP" | cut -f1)"
        [[ -x "$APP" ]] && linha_diag "Permissão de execução" "ok" "$GREEN" \
                        || linha_diag "Permissão de execução" "FALTANDO" "$RED"
        verificar_libs
    else
        err "Executável não encontrado: $APP"
    fi

    echo -e "\n${BOLD}── Rede ─────────────────────────────────────${NC}"
    verificar_ip_publico

    local porta; porta=$(cfg .Porta); porta="${porta:-3000}"
    if ss -uanl 2>/dev/null | grep -q ":$porta"; then
        ok "Porta UDP $porta está aberta pelo processo."
    else
        warn "Nada escutando em UDP $porta (servidor parado?)."
    fi

    # Buffer CONCEDIDO x pedido: se diferentes, o processo subiu antes do
    # sysctl e precisa de restart.
    local rb pedido
    rb=$(ss -uanm 2>/dev/null | grep -A1 ":$porta" | grep -oP 'rb\K[0-9]+' | head -1)
    pedido=$(cfg .Rede.KcpRecvBufferSize)
    if [[ -n "${rb:-}" ]]; then
        linha_diag "Buffer recv PEDIDO" "${pedido:-?} bytes"
        if [[ -n "$pedido" ]] && (( rb < pedido )); then
            linha_diag "Buffer recv CONCEDIDO" "$rb bytes — CORTADO" "$RED"
            warn "O kernel cortou o buffer. Rode a instalação (1) e REINICIE o servidor."
        else
            linha_diag "Buffer recv CONCEDIDO" "$rb bytes" "$GREEN"
        fi
    fi

    linha_diag "rmem_max / wmem_max" \
        "$(sysctl -n net.core.rmem_max 2>/dev/null) / $(sysctl -n net.core.wmem_max 2>/dev/null)"

    echo -e "\n${BOLD}── Relógio ──────────────────────────────────${NC}"
    linha_diag "Fuso" "$(timedatectl show -p Timezone --value 2>/dev/null)"
    linha_diag "NTP sincronizado" "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    command -v chronyc >/dev/null 2>&1 && \
        chronyc tracking 2>/dev/null | grep -E "Reference ID|System time" | sed 's/^/  /'

    echo -e "\n${BOLD}── Serviço ──────────────────────────────────${NC}"
    if [[ -f "$UNIT_PATH" ]]; then
        local tstop rpe
        tstop=$(systemctl show -p TimeoutStopUSec --value "$SERVICE_NAME" 2>/dev/null)
        linha_diag "TimeoutStopSec (unit)" "$tstop"
        linha_diag "Espera do wrapper" \
            "${STOP_WAIT_GRACIOSO}s (console) + ${STOP_WAIT_TERM}s (SIGTERM) = ${STOP_WAIT_WRAPPER}s"
        (( STOP_WAIT_WRAPPER >= STOP_WAIT_SYSTEMD )) && \
            warn "  Wrapper (${STOP_WAIT_WRAPPER}s) >= systemd (${STOP_WAIT_SYSTEMD}s): o systemd mataria antes."

        rpe=$(systemctl show -p RestartPreventExitStatus --value "$SERVICE_NAME" 2>/dev/null)
        if [[ "$rpe" == *"$EXIT_DESLIGAR"* ]]; then
            linha_diag "Comando 'shutdown' (exit $EXIT_DESLIGAR)" "desliga sem reiniciar" "$GREEN"
        else
            linha_diag "Comando 'shutdown' (exit $EXIT_DESLIGAR)" "unit antiga — rode a opção 1" "$YELLOW"
        fi

        local mh
        mh=$(systemctl show -p MemoryHigh --value "$SERVICE_NAME" 2>/dev/null)
        if [[ "$mh" != "infinity" && -n "$mh" ]]; then
            linha_diag "MemoryHigh" "$mh — reclaim forçado, remova" "$RED"
        else
            linha_diag "MemoryHigh" "infinity (correto)" "$GREEN"
        fi
        linha_diag "MemoryMax" \
            "$(systemctl show -p MemoryMax --value "$SERVICE_NAME" 2>/dev/null)"
        linha_diag "Reinício diário" "$(status_restart_timer)"
    else
        err "Unit não instalada. Rode a opção 1."
    fi

    echo -e "\n${BOLD}── Reboot automático ────────────────────────${NC}"
    if [[ -f /etc/apt/apt.conf.d/99-decay-no-reboot ]]; then
        ok "unattended-upgrades não vai reiniciar sozinho."
    else
        warn "unattended-upgrades pode reiniciar a máquina no meio de um raid."
    fi

    pausar
}

# ============================================================
#  MENU
# ============================================================
menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${CYAN}║         DECAY · PAINEL DO SERVIDOR          ║${NC}"
        echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════╝${NC}"
        echo -e "  ${SERVER_DIR}"
        echo -e "  Estado: $(status_curto)"
        esta_rodando && resumo_recursos
        echo -e "  Reinício diário: $(status_restart_timer)"
        echo ""
        echo "  1) Instalar / atualizar (apt, permissões, swap, sysctl, unit)"
        echo "  2) Iniciar servidor"
        echo "  3) Parar servidor (save final confirmado)"
        echo "  4) Reiniciar servidor (save + backup + espera ficar pronto)"
        echo -e "  5) Console + Logs ${GREEN}(tmux)${NC}"
        echo "  6) Status & Monitor"
        echo -e "  7) Backup dos saves ${YELLOW}(antes de cada deploy)${NC}"
        echo -e "  8) Diagnóstico ${CYAN}(saúde do save e da rede)${NC}"
        echo -e "  9) Verificar ambiente ${CYAN}(IP, libs, buffers, relógio)${NC}"
        echo -e " 10) Reinício programado ${CYAN}(diário, com avisos)${NC}"
        echo "  0) Sair (servidor continua rodando)"
        echo ""
        read -r -p "  Escolha: " opt

        case "$opt" in
            1)  acao_instalar ;;
            2)  acao_iniciar ;;
            3)  acao_parar ;;
            4)  acao_reiniciar ;;
            5)  acao_console ;;
            6)  acao_monitor ;;
            7)  acao_backup ;;
            8)  acao_diagnostico ;;
            9)  acao_ambiente ;;
            10) acao_reinicio_programado ;;
            0)  echo "Saindo. O servidor continua em segundo plano."; exit 0 ;;
            *)  warn "Opção inválida."; sleep 1 ;;
        esac
    done
}

# ============================================================
case "${1:-}" in
    __run)      run_launcher ;;
    __prompt)   run_prompt ;;
    __tail)     run_tail ;;
    __restart)  run_restart_agendado ;;
    *)          menu ;;
esac