# Automação de ciclo de vida de dispositivos

Este pacote foi preparado para execução diária no servidor que hospeda o
Microsoft Entra Connect Sync.

## Configuração da organização

Toda a identidade da organização é centralizada em uma única chave no arquivo
`DeviceLifecycle.Config.psd1`:

```powershell
OrganizationName = 'orgname'   # ← altere para o nome da sua organização
```

A partir desse valor, o script deriva automaticamente:

- Pasta de instalação: `C:\ProgramData\{OrganizationName}\DeviceLifecycle`
- Nome da tarefa agendada: `{OrganizationName} - Device Lifecycle`
- Nome do certificado: `CN={OrganizationName} Device Lifecycle Automation`
- Arquivo do certificado: `{OrganizationName}-DeviceLifecycle.cer`

Todos esses valores podem ser sobrescritos individualmente no arquivo de
configuração se necessário.

## Arquitetura adotada

- Computadores ativos continuam diretamente na OU de computadores configurada
  (ex.: `OU=Computadores,DC=corp,DC=orgname,DC=com,DC=br`)
- A automação cria e utiliza a OU de quarentena configurada
  (ex.: `OU=Quarentena,OU=Computadores,DC=corp,DC=orgname,DC=com,DC=br`)
- 75 dias sem atividade: entra no relatório de atenção.
- 90 dias sem atividade nos três sinais: candidato à quarentena.
- Quarentena: `Retire` no Intune, desabilitação no AD e movimentação para a OU.
- O `Retire` pode remover o registro `managedDevice` do Intune antes do fim da
  quarentena; o script preserva os identificadores e timestamps no arquivo de
  estado para continuar o fluxo com segurança.
- 30 dias adicionais em quarentena: exclusão do AD e de qualquer registro
  residual do Intune.
- O Entra Connect executa `Delta Sync` para remover o dispositivo híbrido do
  Entra ID.
- Se o objeto do Entra continuar existindo por 7 dias após a exclusão no AD,
  o modo `Enforce` remove o objeto residual pelo Microsoft Graph.

A decisão automática exige correlação não ambígua:

1. SID do computador no AD ↔ `onPremisesSecurityIdentifier` no Entra ID.
2. `deviceId` do Entra ID ↔ `azureADDeviceId` do Intune.
3. Os timestamps do AD, Entra e Intune devem estar além do limite.

Registros ausentes, duplicados ou com timestamp vazio são enviados para
`ManualReview`. Eles não são alterados.

## Cuidado obrigatório com o escopo do Entra Connect

A OU `Quarentena` deve continuar no escopo de sincronização do Entra Connect.

Se ela ficar fora do escopo, mover um computador para a OU fará o objeto ser
removido do Entra imediatamente, eliminando o período de carência. Confirme o
filtro de domínio/OU antes de habilitar `Quarantine` ou `Enforce`.

## 1. Preparar os arquivos

Copie o diretório para o servidor que executa o Entra Connect Sync e edite:

`DeviceLifecycle.Config.psd1`

Preencha:

- `OrganizationName` (nome curto da organização — define todos os caminhos e nomes)
- `TenantId`
- `ClientId`
- `CertificateThumbprint`

Confirme também os DNs das OUs, o nome do servidor em `ExcludedComputerNames`
e se `extensionAttribute15` não está sendo usado por outro processo.

## 2. Inicializar módulos, OU, grupo e certificado

Execute em PowerShell como administrador:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

.\Initialize-DeviceLifecycle.ps1 `
    -InstallModules `
    -CreateAdObjects `
    -CreateCertificate
```

O comando exibirá:

- thumbprint do certificado;
- caminho do arquivo público `.cer`;
- confirmação da OU e do grupo de exclusão.

Copie o thumbprint para `DeviceLifecycle.Config.psd1`.

## 3. Criar a App Registration

No Microsoft Entra admin center:

1. Crie uma App Registration chamada `{OrganizationName} Device Lifecycle Automation`
   (ex.: `Launer Device Lifecycle Automation`).
2. Em **Certificates & secrets > Certificates**, envie o arquivo:
   `C:\ProgramData\{OrganizationName}\DeviceLifecycle\{OrganizationName}-DeviceLifecycle.cer`
3. Adicione estas permissões **Application** do Microsoft Graph:
   - `Device.ReadWrite.All`
   - `DeviceManagementManagedDevices.ReadWrite.All`
   - `DeviceManagementManagedDevices.PrivilegedOperations.All`
   - `DeviceManagementServiceConfig.Read.All`
4. Conceda **Admin consent**.
5. Copie o `Application (client) ID` e o `Directory (tenant) ID` para o arquivo
   de configuração.

`Device.ReadWrite.All` é necessário para consultar os dispositivos e remover
um objeto residual do Entra depois que o objeto correspondente já tiver sido
excluído do AD.

## 4. Permissões no AD

A tarefa é instalada como `NT AUTHORITY\SYSTEM`. No domínio, ela atua como a
conta de computador:

`DOMINIO\NOME-DO-SERVIDOR$`

Delegue a essa conta, somente na OU `Computadores` e na OU `Quarentena`, as
permissões necessárias para:

- ler objetos e propriedades de computador;
- escrever `userAccountControl` para desabilitar a conta;
- escrever `extensionAttribute15`;
- mover objetos de computador para a OU `Quarentena`;
- excluir objetos de computador dentro da OU `Quarentena`.

Não conceda Domain Admin.

Para o primeiro teste, também é possível executar manualmente com uma conta
administrativa e configurar a delegação antes de instalar a tarefa.

## 5. Validar dependências

```powershell
.\Test-DeviceLifecycle.ps1
```

Todos os testes devem aparecer como `True`.

## 6. Executar o primeiro inventário

O arquivo já vem em:

```powershell
Mode = 'ReportOnly'
```

Execute:

```powershell
.\Invoke-DeviceLifecycle.ps1
```

Relatórios:

`C:\ProgramData\{OrganizationName}\DeviceLifecycle\Reports`

Logs:

`C:\ProgramData\{OrganizationName}\DeviceLifecycle\Logs`

Analise especialmente:

- `ManualReview`
- `MissingEntraMatch`
- `MissingIntuneMatch`
- `AmbiguousEntraMatch`
- `AmbiguousIntuneMatch`
- `MissingActivityTimestamp`
- `QuarantineCandidate`

Durante a implantação piloto do Intune, mantenha:

```powershell
RequireIntuneMatch = $true
```

Assim, computadores ainda não matriculados no Intune não serão alterados.

## 7. Instalar a tarefa agendada

Depois de validar o arquivo de configuração:

```powershell
.\Install-DeviceLifecycleTask.ps1 -ForceConfig
```

A tarefa será criada como:

`{OrganizationName} - Device Lifecycle`

Execução diária padrão:

`02:15`

## 8. Ativação em fases

### Fase 1 — relatório

Mantenha por pelo menos duas semanas:

```powershell
Mode = 'ReportOnly'
```

### Fase 2 — quarentena

Após validar os candidatos:

```powershell
Mode = 'Quarantine'
```

Esse modo não faz exclusões definitivas.

### Fase 3 — aplicação completa

Depois de testar recuperação e confirmar as chaves BitLocker:

```powershell
Mode = 'Enforce'
```

## Recuperação durante a quarentena

A recuperação deve ser manual:

1. habilitar o computador no AD;
2. mover o objeto de volta para `OU=Computadores`;
3. limpar `extensionAttribute15`;
4. remover o respectivo registro de `state.json`, se necessário;
5. iniciar um `Delta Sync`;
6. validar a junção híbrida e a matrícula do Intune.

A automação não reativa automaticamente um equipamento. Uma sincronização do
Intune depois da quarentena pode ser apenas o recebimento do comando `Retire`;
por isso, a permanência na OU, a conta AD desabilitada e a data de quarentena
são o estado autoritativo.

Use o script de recuperação:

```powershell
.\Restore-QuarantinedDevice.ps1 -ComputerName NOME-DO-PC -WhatIf
.\Restore-QuarantinedDevice.ps1 -ComputerName NOME-DO-PC
```

Depois, valide a junção híbrida e a matrícula do Intune, pois um `Retire`
concluído pode exigir novo enrollment.

## Proteções implementadas

- `ReportOnly` como padrão;
- correlação por SID e GUID, não apenas pelo nome;
- objetos Autopilot excluídos;
- servidores e controladores de domínio excluídos;
- servidor de execução excluído (nome configurado em ExcludedComputerNames);
- grupo de exceções;
- objetos protegidos contra exclusão enviados para revisão manual;
- limite máximo de 10 dispositivos alterados por execução;
- estado persistente em JSON, inclusive após o `Retire` remover o registro do
  Intune;
- CSV e log por execução;
- remoção residual do Entra somente depois da exclusão no AD;
- suporte a `-WhatIf`.

Exemplo de simulação:

```powershell
.\Invoke-DeviceLifecycle.ps1 -ModeOverride Enforce -WhatIf
```
## ⚠ Desinstalação completa

Use o script `Uninstall-DeviceLifecycle.ps1` para remover completamente a
automação do servidor — PowerShell modules e o provedor NuGet são
intencionalmente preservados pois podem ser compartilhados com outros projetos.
Ele remove por fases:

| Fase | O que remove |
|---|---|
| 1. Scheduled Task | Desregistra a tarefa agendada |
| 2. Install Directory | Exclui `C:\ProgramData\{OrganizationName}\DeviceLifecycle\` (logs, reports, state.json, scripts, .cer) |
| 3. Certificate | Remove o certificado auto-assinado do `Cert:\LocalMachine\My` |
| 4. AD Objects | Remove a OU de quarentena (se vazia), o grupo de exclusão e limpa `extensionAttribute15` dos computadores |

### Exemplos de uso

```powershell
# Visualizar tudo que seria removido (sem executar):
.\Uninstall-DeviceLifecycle.ps1 -WhatIf

# Remoção interativa completa (pede confirmação em cada fase):
.\Uninstall-DeviceLifecycle.ps1

# Remover apenas a tarefa agendada e o diretório,
# mantendo AD e certificado:
.\Uninstall-DeviceLifecycle.ps1 -SkipAdCleanup -SkipCertificate

# Remoção completa não interativa (sem confirmações):
.\Uninstall-DeviceLifecycle.ps1 -Force
```

### Sequência recomendada

1. **Alterar o modo para `ReportOnly`** no arquivo de configuração e executar
   `Install-DeviceLifecycleTask.ps1 -ForceConfig` para atualizar a tarefa.
   Isso garante que nenhuma nova ação automática seja disparada.

2. **Executar** `.\Uninstall-DeviceLifecycle.ps1 -WhatIf` para revisar tudo que
   será removido.

3. **Executar** `.\Uninstall-DeviceLifecycle.ps1` para remoção interativa.

4. **Verificar manualmente** se todos os objetos AD residuais foram removidos.

### Cuidados importantes

- **Logs e relatórios são perdidos permanentemente** quando o diretório de
  instalação é removido. Faça backup antes se necessário.
- **A limpeza do `extensionAttribute15` não reverte quarentenas já aplicadas**.
  Computadores em quarentena precisam ser recuperados manualmente antes da
  desinstalação (use `Restore-QuarantinedDevice.ps1`).
- **A OU de quarentena só é removida se estiver vazia**. Mova computadores
  para fora da OU antes de tentar removê-la.
- **O script requer execução como administrador** e acesso ao módulo
  `ActiveDirectory` para a limpeza AD.

## Extensão opcional: DeviceLifecycle-API

Este repositório possui uma extensão HTTP opcional, mantida separadamente no
repositório `DeviceLifecycle-API`. A extensão publica, em modo somente leitura,
o CSV mais recente e o log mais recente gerados por esta automação.

A API não executa ações no Active Directory, Entra ID, Intune ou Microsoft
Graph e não é necessária para o funcionamento do `DeviceLifecycle`. O serviço
principal continua sendo a fonte autoritativa e responsável por produzir os
dados.

A instalação recomendada é no mesmo servidor que armazena os relatórios e logs.
Depois disso, qualquer servidor ou sistema interno autorizado pode consumir os
dados para dashboards, inventário, monitoramento, auditoria ou outras
integrações. O acesso é protegido por API key e por regra de firewall restrita
aos consumidores configurados.

Endpoints disponibilizados pela extensão:

- CSV original: `GET /api/v1/report.csv`
- Relatório convertido para JSON: `GET /api/v1/report`
- Últimas linhas do log: `GET /api/v1/log?lines=500`
- Log completo: `GET /api/v1/log/file`
- Metadados dos arquivos: `GET /api/v1/metadata`
- Estado do serviço: `GET /api/v1/health`

Consulte o README e a documentação do repositório separado
`DeviceLifecycle-API` para instalação, autenticação e contrato HTTP completo.
