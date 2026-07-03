=== GUIA DE CONFIGURAÇÃO DO SERVIDOR ===

[Identidade]
ServerId          - UUID único do servidor. Não repita entre servidores diferentes.
NomeDoServidor     - Nome exibido na lista de servidores.
DescricaoServidor  - Texto curto sobre o servidor.
DiscordUrl         - Link do Discord (opcional, deixe vazio se não usar).

[Rede]
IPDoServidor       - IP público ou local do servidor.
Porta              - Porta de conexão (padrão Mirror: 7777).
Regiao             - Sigla da região (ex: BR, US, EU).

[Master Server]
MasterBaseUrl      - URL do master server de autenticação (ex: http://localhost:8080).
ServerKey          - Chave secreta compartilhada com o master server. NUNCA divulgue.

[Jogo]
MaxPlayers         - Número máximo de jogadores simultâneos.
MapId              - Identificador do mapa carregado.
BuildVersion       - Versão do cliente aceita para conectar.
TipoServidor       - Community, Official ou Modded.

[Balanceamento]
BalanceamentoArmaduras   - Multiplicador de dano/resistência de armaduras.
MultiplicadorDeColetas   - Multiplicador de itens coletados (1 = padrão).

[Permissões de Plataforma]
PlataformasPermitidas - "PC", "Mobile" ou "Ambos". Define quem pode conectar.

[Moderação]
JogadoresBanidos  - Lista de PlayerIds banidos. Editável manualmente ou via Banir()/Desbanir().