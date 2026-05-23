# Pipeline CI/CD Salesforce — Documentação Completa

## Visão Geral

Este repositório utiliza 6 workflows do GitHub Actions que, juntos, formam um pipeline completo de CI/CD para Salesforce. O fluxo garante qualidade de código, homologação, governança (GMUD) e rastreabilidade em cada deploy.

```
Feature Branch ──► PR aberto ──► CI Validate ──► Code Review (2x)
                                                       │
                                                       ▼
                                                  Deploy UAT
                                                       │
                                                       ▼
                                              Homologação (squad)
                                                       │
                                                       ▼
                                            Label "homologado"
                                                       │
                                                       ▼
                                          GMUD aprovada no CoE
                                                       │
                                                       ▼
                                         Label "GMUD-XXXX" no PR
                                                       │
                                                       ▼
                                    GMUD Gate ✅ ──► Merge na main
                                                       │
                                                       ▼
                                              Deploy PRD (auto)
                                              Notify Rebase (auto)
                                                       │
                                                       ▼
                                            (se problema) Rollback PRD
```

---

## 1. CI - Validate PR (`ci-validate.yml`)

### O que faz

Executa um dry-run (validação sem deploy real) na org CI com testes Apex locais. Garante que o código compila e os testes passam antes de qualquer deploy.

### Gatilho

```yaml
on:
  pull_request:
    branches: [main]
    paths: ['force-app/**']
    types: [opened, synchronize, reopened]
```

| Evento | Quando dispara |
|--------|----------------|
| `opened` | Dev abre um PR apontando para `main` |
| `synchronize` | Dev faz push de novos commits na branch do PR |
| `reopened` | PR que foi fechado é reaberto |

Só dispara se houver alterações dentro de `force-app/`.

### Como é disparado

Automaticamente. O dev não precisa fazer nada além de abrir o PR ou fazer push na branch.

### O que acontece

1. Faz checkout do código
2. Instala o Salesforce CLI
3. Autentica na org CI usando o secret `SF_CI_AUTH_URL`
4. Executa `sf project deploy validate` com `RunLocalTests` (dry-run)
5. Se falhar, comenta no PR com a mensagem de erro

### Pré-requisitos

- Secret `SF_CI_AUTH_URL` configurado com a SFDX Auth URL da org CI

### Resultado

- **Passou**: O PR recebe o status check verde "Validate in CI Org"
- **Falhou**: Comentário no PR com `❌ CI Validation falhou` e status check vermelho

---

## 2. Deploy UAT (`deploy-uat.yml`)

### O que faz

Deploya a feature branch na org UAT para homologação. Só executa quando o PR já passou no CI e tem pelo menos 2 aprovações de code review.

### Gatilho

```yaml
on:
  pull_request_review:
    types: [submitted]
    branches: [main]
```

| Evento | Quando dispara |
|--------|----------------|
| `submitted` | Alguém submete um review no PR (aprovação, comentário ou changes requested) |

O workflow só prossegue se `github.event.review.state == 'approved'`.

### Como é disparado

Automaticamente quando um reviewer aprova o PR. O fluxo:

1. Primeiro reviewer aprova → workflow roda, mas detecta que falta 1 aprovação → não deploya
2. Segundo reviewer aprova → workflow roda, detecta CI ok + 2 aprovações → deploya em UAT

### O que acontece

1. Verifica se o CI passou (status check "Validate in CI Org" = SUCCESS)
2. Conta quantas aprovações únicas o PR tem (mínimo 2)
3. Se ambas as condições ok, faz checkout da feature branch
4. Verifica se a branch está atualizada com a `main` (sem commits atrás)
5. Se a branch estiver desatualizada, bloqueia e comenta instruções de rebase
6. Autentica na org UAT usando `SF_UAT_AUTH_URL`
7. Executa `sf project deploy start` com `RunLocalTests`
8. Comenta no PR o resultado (sucesso ou falha)

### Pré-requisitos

- Secret `SF_UAT_AUTH_URL` configurado
- CI deve ter passado
- Mínimo de 2 aprovações de code review
- Branch atualizada com a `main`

### Resultado

- **Passou**: Comentário no PR com `✅ Deploy UAT realizado com sucesso` e instruções dos próximos passos
- **Falhou**: Comentário no PR com `❌ Deploy UAT falhou`
- **Branch desatualizada**: Comentário com `⚠️ Deploy UAT bloqueado` e instruções de rebase

---

## 3. GMUD Gate (`gmud-gate.yml`)

### O que faz

Valida que a homologação foi concluída E que uma GMUD aprovada está associada ao PR. Funciona como Required Status Check — o merge na `main` só é liberado quando ambas as labels estão presentes.

### Gatilho

```yaml
on:
  pull_request:
    branches: [main]
    types: [labeled, unlabeled, opened, synchronize]
```

| Evento | Quando dispara |
|--------|----------------|
| `labeled` | Alguém adiciona uma label no PR |
| `unlabeled` | Alguém remove uma label do PR |
| `opened` | PR é aberto |
| `synchronize` | Novo push na branch do PR |

### Como é disparado

Automaticamente, mas depende de ações manuais:

1. Após homologação em UAT, o **QA ou Tech Lead** adiciona a label `homologado` no PR → workflow dispara
2. Após aprovação da GMUD no CoE, o **Release Manager** adiciona a label `GMUD-XXXX` (com número real, ex: `GMUD-4821`) → workflow dispara novamente

### O que acontece

1. Lê as labels diretamente do payload do evento (sem chamada à API)
2. Verifica se a label `homologado` está presente
3. Se sim, verifica se existe uma label no formato `GMUD-` seguido de números
4. Se ambas presentes, o check passa e o merge é liberado

### Pré-requisitos

- Label `homologado` no PR
- Label `GMUD-XXXX` no PR (com número real da GMUD)
- Configurar `Validate Homologation & GMUD` como Required Status Check em Settings > Branches > main

### Resultado

| Status | Labels presentes |
|--------|-----------------|
| ❌ Falhou | Nenhuma label |
| ❌ Falhou | Só `homologado` |
| ❌ Falhou | Só `GMUD-XXXX` |
| ✅ Passou | `homologado` + `GMUD-XXXX` |

---

## 4. Deploy PRD (`deploy-prd.yml`)

### O que faz

Deploya o código em produção após o merge na `main`. Executa validate (dry-run) seguido de quick deploy. Cria uma tag de rastreabilidade com informações do PR e da GMUD.

### Gatilho

```yaml
on:
  push:
    branches: [main]
    paths: ['force-app/**']
```

| Evento | Quando dispara |
|--------|----------------|
| `push` | Qualquer push na branch `main` que altere `force-app/` |

Na prática, é disparado automaticamente quando um PR é mergeado na `main`.

### Como é disparado

Automaticamente pelo merge do PR. Porém, o workflow para e **aguarda aprovação manual** dos aprovadores configurados no Environment `PRD`.

Fluxo:
1. PR é mergeado na `main` → push detectado → workflow inicia
2. Workflow **para** no environment `PRD` e aguarda aprovação
3. Aprovador do environment aprova no GitHub Actions
4. Deploy prossegue

### O que acontece

1. Extrai informações do PR mergeado (número, título, autor, GMUD)
2. Instala Salesforce CLI
3. Autentica na org PRD usando `SF_PRD_AUTH_URL`
4. Executa `sf project deploy validate` (dry-run com testes)
5. Se validação ok, executa `sf project deploy quick` (quick deploy)
6. Cria tag no formato `prd-YYYYMMDD-HHMMSS` com metadados do PR e GMUD
7. Comenta no PR original o resultado do deploy

### Pré-requisitos

- Secret `SF_PRD_AUTH_URL` configurado
- Environment `PRD` configurado em Settings > Environments com aprovadores
- Merge na `main` ter ocorrido (normalmente via PR aprovado pelo GMUD Gate)

### Resultado

- **Passou**: Tag criada, comentário no PR com `🚀 Deploy PRD realizado com sucesso`
- **Falhou**: Comentário no PR com `❌ Deploy PRD falhou` e orientação para investigar/rollback

---

## 5. Notify Rebase Needed (`notify-rebase.yml`)

### O que faz

Após um merge na `main`, notifica todos os PRs abertos de que precisam fazer rebase para se manterem atualizados.

### Gatilho

```yaml
on:
  push:
    branches: [main]
    paths: ['force-app/**']
```

| Evento | Quando dispara |
|--------|----------------|
| `push` | Qualquer push na `main` que altere `force-app/` |

Disparado junto com o Deploy PRD — ambos escutam o mesmo evento.

### Como é disparado

Automaticamente pelo merge do PR. Não requer nenhuma ação manual.

### O que acontece

1. Identifica qual PR foi mergeado
2. Lista todos os PRs abertos apontando para `main`
3. Comenta em cada PR aberto (exceto o que foi mergeado) com `⚠️ Rebase necessário`
4. Inclui instruções de rebase (`git fetch`, `git rebase`, `git push --force-with-lease`)

### Pré-requisitos

Nenhum secret adicional — usa o `GITHUB_TOKEN` padrão.

### Resultado

Cada PR aberto recebe um comentário com aviso de rebase e instruções. O deploy-uat.yml bloqueia o deploy se a branch não estiver atualizada, reforçando a necessidade do rebase.

---

## 6. Rollback PRD (`rollback-prd.yml`)

### O que faz

Reverte um PR específico da `main`, desfazendo o deploy em produção. Cria um commit de revert que, ao ser pushado na `main`, dispara automaticamente o Deploy PRD com o código revertido.

### Gatilho

```yaml
on:
  workflow_dispatch:
    inputs:
      pr_number:
        description: 'Número do PR a reverter (ex: 142)'
        required: true
      reason:
        description: 'Motivo do rollback'
        required: true
```

| Evento | Quando dispara |
|--------|----------------|
| `workflow_dispatch` | Execução manual pela interface do GitHub Actions |

### Como é disparado

**Manualmente.** O processo:

1. Ir em Actions > Rollback PRD > Run workflow
2. Preencher o número do PR a reverter (ex: `142`)
3. Preencher o motivo do rollback
4. Clicar em "Run workflow"
5. Aguardar aprovação dos aprovadores do Environment `PRD`

### O que acontece

1. Faz checkout com `GH_PAT` (Personal Access Token com permissão de push em branches protegidas)
2. Localiza o merge commit do PR informado
3. Executa `git revert -m 1` do merge commit
4. Faz push do revert na `main`
5. Cria tag no formato `rollback-prXXX-YYYYMMDD-HHMMSS`
6. Comenta no PR original com `🔴 ROLLBACK EXECUTADO` e instruções para a squad
7. O push na `main` dispara automaticamente o Deploy PRD e o Notify Rebase

### Pré-requisitos

- Secret `GH_PAT` com Personal Access Token que tenha permissão de push em branches protegidas
- Environment `PRD` configurado com aprovadores
- O PR informado deve ter sido mergeado na `main`

### Resultado

- Commit de revert na `main`
- Deploy PRD automático com o código revertido (restaura estado anterior)
- Comentário no PR original com detalhes do rollback
- Notificação de rebase em todos os PRs abertos

### Após o rollback

A squad que teve o PR revertido deve:

1. Investigar o problema na feature branch
2. Corrigir o bug
3. Abrir **novo PR** com a mudança original + correção
4. Passar por todo o fluxo novamente (CI → UAT → GMUD → PRD)

---

## Sequência Completa do Pipeline

### Fluxo normal (sem problemas)

```
 FASE                AÇÃO                            QUEM              WORKFLOW
─────────────────────────────────────────────────────────────────────────────────
 1. Desenvolvimento  Push na feature branch           Dev               —
 2. PR               Abre PR para main                Dev               —
 3. CI               Validação automática             Automático        ci-validate
 4. Code Review      1ª aprovação                     Reviewer 1        —
 5. Code Review      2ª aprovação                     Reviewer 2        deploy-uat (auto)
 6. UAT              Deploy automático em UAT         Automático        deploy-uat
 7. Homologação      Testa em UAT                     Squad/QA          —
 8. Label            Adiciona "homologado"            QA/Tech Lead      gmud-gate (auto)
 9. GMUD             Abre GMUD na ferramenta          Dev/Tech Lead     —
10. GMUD             Aprovação no fórum do CoE        CoE               —
11. Label            Adiciona "GMUD-XXXX"             Release Manager   gmud-gate (auto)
12. Merge            GMUD Gate ✅ → merge habilitado  Dev/Tech Lead     —
13. PRD              Aguarda aprovação do environment  Aprovador PRD     deploy-prd
14. PRD              Deploy automático em PRD         Automático        deploy-prd
15. Rebase           Notifica PRs abertos             Automático        notify-rebase
16. Validação        Valida em produção               Squad             —
```

### Fluxo com rollback

```
 FASE                AÇÃO                            QUEM              WORKFLOW
─────────────────────────────────────────────────────────────────────────────────
 1. Problema         Identificado bug em PRD          Squad/Monitoração —
 2. Rollback         Executa rollback manual          Release Manager   rollback-prd
 3. Aprovação        Aprova no environment PRD        Aprovador PRD     rollback-prd
 4. Revert           Commit de revert na main         Automático        rollback-prd
 5. Deploy           Deploy do revert em PRD          Automático        deploy-prd
 6. Correção         Squad corrige na feature branch  Dev               —
 7. Novo PR          Abre novo PR com correção        Dev               ci-validate (reinicia)
```

---

## Secrets Necessários

| Secret | Descrição | Usado em |
|--------|-----------|----------|
| `SF_CI_AUTH_URL` | SFDX Auth URL da org CI | ci-validate |
| `SF_UAT_AUTH_URL` | SFDX Auth URL da org UAT | deploy-uat |
| `SF_PRD_AUTH_URL` | SFDX Auth URL da org PRD | deploy-prd |
| `GH_PAT` | Personal Access Token com push em branches protegidas | rollback-prd |
| `GITHUB_TOKEN` | Automático do GitHub (não precisa configurar) | Todos |

Para gerar uma SFDX Auth URL:
```bash
sf org display --verbose --json | jq -r '.result.sfdxAuthUrl'
```

---

## Configurações do Repositório

### Branch Protection Rules (main)

Em Settings > Branches > Branch protection rules > main:

- ✅ Require a pull request before merging
- ✅ Require approvals: 2
- ✅ Require status checks to pass before merging
  - `Validate in CI Org` (ci-validate)
  - `Validate Homologation & GMUD` (gmud-gate)
- ✅ Require branches to be up to date before merging

### Environments

Em Settings > Environments:

- **PRD**: Configurar Required reviewers (aprovadores do deploy em produção)