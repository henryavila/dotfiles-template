# Syncthing setup — pairing + folders (`~/.claude/` + `~/.claude-mem/`)

Guia passo-a-passo para configurar sync entre N máquinas pessoais. **Pré-requisito**: Syncthing já instalado e rodando em cada máquina (via topic `80-claude-code` do `dev-bootstrap`). Confira com:

```bash
systemctl --user is-active syncthing.service   # Linux/WSL
brew services list | grep syncthing            # Mac
pgrep -f 'syncthing serve'                     # fallback universal
```

---

## Modelo mental

Você vai configurar **2 folders separadas** no Syncthing em cada máquina:

| Folder ID | Path | Conteúdo | `.stignore` |
|-----------|------|----------|-------------|
| `claude-config` | `~/.claude` | skills, agents, commands, rules, hooks, marketplaces, settings.json | `claude/stignore/claude-config.stignore` |
| `claude-mem` | `~/.claude-mem` | SQLite DB + chroma embeddings | `claude/stignore/claude-mem.stignore` |

A separação em 2 folders dá controle granular: você pode pausar uma (ex: durante merge do claude-mem DB) sem afetar a outra.

---

## Fase 1 — Setup na "máquina golden" (M1)

Escolha uma máquina como source-of-truth inicial (geralmente a mais atualizada).

1. **Abra o Web UI**: http://localhost:8384

2. **Setar senha** (Settings → GUI):
   - User Name: `henry` (ou qualquer)
   - Password: gere no password manager
   - Use HTTPS: on (opcional)

3. **Pegar o Device ID** (Actions → Show ID):
   - Grave pra usar nas outras máquinas

4. **Adicionar a folder `claude-config`** (Add Folder):
   - Folder ID: `claude-config`  ← importante, será usado em todas as máquinas
   - Folder Path: `/home/<user>/.claude` (ou `/Users/<user>/.claude` no Mac)
   - Folder Type: **Send Only** ← CRÍTICO nesta fase inicial
   - Ignore Patterns: **cole o conteúdo de `~/dotfiles/claude/stignore/claude-config.stignore`**
   - Save

5. **Adicionar a folder `claude-mem`**:
   - Folder ID: `claude-mem`
   - Folder Path: `/home/<user>/.claude-mem`
   - Folder Type: **Send Only**
   - Ignore Patterns: cole `claude/stignore/claude-mem.stignore`
   - Save

---

## Fase 2 — Setup em cada máquina receptora (M2, M3, M4)

**⚠️ IMPORTANTE**: antes de parear, **mova o `~/.claude/` e `~/.claude-mem/` atuais** pra um backup local — Syncthing vai sobrescrever com o conteúdo da M1.

```bash
mv ~/.claude ~/.claude.pre-sync-$(date +%Y%m%d)
mv ~/.claude-mem ~/.claude-mem.pre-sync-$(date +%Y%m%d)
mkdir -p ~/.claude ~/.claude-mem
```

(Você já tem um backup `.tgz` completo da Fase 0 do playbook; este `mv` é redundante mas barato e dá segurança extra.)

1. **Abra o Web UI**: http://localhost:8384

2. **Adicionar o device M1** (Add Remote Device):
   - Device ID: cole o ID da M1
   - Name: `m1-hostname` (qualquer label)
   - Introducer: **off** inicialmente (ative depois que tudo funcionar, simplifica pairing de máquinas futuras)
   - Save

3. **Aceitar as folders que M1 compartilhou** (aparece como notificação após M1 compartilhar):
   - `claude-config` → Folder Type: **Receive Only**; Path: `~/.claude`
   - `claude-mem` → Folder Type: **Receive Only**; Path: `~/.claude-mem`
   - Save

4. **Na M1**, aceitar o share de volta (notificação aparece):
   - Share `claude-config` com M2 → Save
   - Share `claude-mem` com M2 → Save

5. **Aguardar sync completo** — a folder mostra "Up to Date" no status. Leva 5–30min dependendo de tamanho + rede.

Repetir passos 1–5 para M3, M4. Após a primeira máquina, você pode habilitar **Introducer** na M1 — daí M2, M3, M4 se conhecem mutuamente sem você ter que parear todas as combinações.

---

## Fase 3 — Flip para bidirectional (após sync completo + validação)

Uma vez que todas as N máquinas mostram "Up to Date" nas 2 folders:

**Em M1** (Web UI → folder → Edit):
- `claude-config` Folder Type: **Send & Receive** (antes era Send Only)
- `claude-mem` Folder Type: **Send & Receive**

**Em M2, M3, M4**:
- `claude-config` Folder Type: **Send & Receive** (antes era Receive Only)
- `claude-mem` Folder Type: **Send & Receive**

A partir deste momento: qualquer mudança em qualquer máquina propaga pras outras. **Zero intervenção manual no dia-a-dia.**

---

## Operação diária

Não há. Você instala skill/plugin/mcp em qualquer máquina, Syncthing propaga em segundos-minutos.

**Convenção**: evite operar Claude Code em 2 máquinas *simultaneamente* no mesmo projeto. É improvável mas: se as duas alterarem o mesmo arquivo (ex: skill SKILL.md) ao mesmo tempo, Syncthing gera conflict files (`sync-conflict-<ts>-<device>.md`). Resolver: abrir ambos, manter o melhor, deletar o outro.

---

## Troubleshooting

### "Folder shows 'Out of Sync' permanentemente"

Provável conflict file ou permissões ruins. Web UI → folder → mostra lista de arquivos problemáticos. Resolve arquivo-por-arquivo.

### "Nova máquina não aparece no device list"

- Firewall bloqueando porta 22000 (TCP sync) ou 21027 (UDP discovery)?
- Rede corporativa pode bloquear Syncthing — tente relay: Settings → Connections → enabled relays.

### "DB do claude-mem corrompido após sync"

WAL/shm sendo sincronizado apesar do `.stignore`? Confere:
```bash
ls -la ~/.claude-mem/*.db-*
```
Se aparecer `.db-shm` ou `.db-wal` na pasta, o `.stignore` não está pegando. Verifique:
```bash
cat ~/.claude-mem/.stignore
```

### "Muitos arquivos modificados, quero ver o que"

Web UI → folder → "Failed" / "Out of Sync" mostra lista. Também:
```bash
syncthing --logflags=0 --verbose
```

---

## Parar temporariamente (ex: durante merge manual)

Web UI → folder → Pause. Reativar depois com Resume.

CLI alternativa:
```bash
curl -X POST -H "X-API-Key: $(grep api-key ~/.config/syncthing/config.xml | sed 's/.*<apikey>//' | sed 's/<.*//')" \
  http://localhost:8384/rest/db/pause -d 'folder=claude-config'
```

(API key está em `~/.config/syncthing/config.xml` — `<apikey>` tag.)
