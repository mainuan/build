# Mita'i OS Builder

Script para construir imagens ISO customizadas do Mita'i OS, baseadas em derivados do Debian/Ubuntu (como o Kubuntu).

## Requisitos

- Sistema operacional baseado em Debian/Ubuntu (host)
- Execução como **root via `sudo -EH`**
- As seguintes dependências são instaladas automaticamente se estiverem faltando:

| Ferramenta | Pacote |
|---|---|
| `mmd` | dosfstools |
| `mcopy` | mtools |
| `grub-mkstandalone` | grub-common |
| `osirrox` | xorriso |
| `unsquashfs` | squashfs-tools |
| `wget` | wget |
| `rsync` | rsync |
| `git` | git |
| `bsdtar` | libarchive-tools |
| — | grub-pc |
| — | grub-efi-amd64-bin |

## Estrutura de diretórios esperada

```
.
├── build.sh
└── data/
    └── <variante>/
        ├── distro.ini                   # Configurações da distro (obrigatório)
        ├── BuildSteps                   # (opcional) lista de etapas customizadas
        ├── remove-base-packages.lst
        ├── launchpad-repositories.lst
        ├── git-dot-files.lst
        ├── pkexec-sudo-white-list.lst
        ├── pin-packages.yaml
        ├── install-deb-packages.lst
        ├── install-apt-packages.lst
        ├── install-flapak-packages.lst
        ├── install-appimage-packages.lst
        ├── install-snap-packages.lst
        ├── hide-apps-from-menu.lst
        ├── reorganize-apps.yaml
        ├── plasma-kcms.yaml
        ├── remove-packages-content.lst
        ├── remove-system-files.lst
        ├── symlinks.lst
        ├── executables.lst
        └── grub-entries.yaml
```

Consulte os arquivos em `data/minimal/` como referência para entender a estrutura e o conteúdo esperado de cada arquivo de configuração.

## Uso

O script **deve** ser executado com `sudo -EH`:

```bash
sudo -EH bash build.sh [opções] [variante] [etapa]
```

### Uso básico

Construir uma imagem usando a ISO padrão do Ubuntu:

```bash
sudo -EH bash build.sh [variante]
```

Construir usando uma URL de ISO customizada:

```bash
sudo -EH bash build.sh --iso="[url ou caminho]" [variante]
```

Se nenhuma variante for informada, o script utiliza a variante `minimal` como padrão.

### Exemplos

```bash
# Build completo com a variante padrão
sudo -EH bash build.sh minimal

# Build usando ISO local
sudo -EH bash build.sh --iso="/home/user/kubuntu-24.04.iso" minimal

# Build usando ISO remota customizada
sudo -EH bash build.sh --iso="https://example.com/minha-iso.iso" minhavariante
```

## Variantes disponíveis

As variantes são os diretórios dentro de `data/`. Para listar:

```bash
ls data/
```

Cada variante precisa ter, no mínimo, um arquivo `distro.ini` com as configurações da distribuição.

### Arquivo `distro.ini`

Este arquivo define as variáveis da distribuição. Exemplo de variáveis usadas pelo script:

```ini
name=MinhaDisto
flavour=kubuntu
base=24.04
flavour_release=noble
system_version=1.0
system_dir=/mitai
type=Desktop
code_name=Meu Codinome
keyboard=br
locale=pt_BR.UTF-8
timezone=America/Sao_Paulo
user=live
host=mitai
logo=mitai
id=mitai
website=https://exemplo.com
contact=https://exemplo.com/contato
donate=https://exemplo.com/doe
release=https://exemplo.com/notas
issues=https://exemplo.com/bugs
help=https://exemplo.com/ajuda
privacy=https://exemplo.com/privacidade
grub_name=Minha Distro
splash=quiet splash
```

## Etapas do build

O build completo executa as seguintes etapas em sequência:

| Etapa | Descrição |
|---|---|
| `check-build-dependencies` | Verifica e instala dependências |
| `download-image` | Baixa a ISO base |
| `extract-image` | Extrai o sistema de arquivos da ISO |
| `mount-virtual-fs` | Monta os sistemas de arquivos virtuais (dev, proc, etc.) |
| `prepare-base-image` | Prepara a imagem base (locale, teclado, kernel) |
| `remove-base-packages` | Remove pacotes indesejados |
| `setup-anti-breakage` | (desativado) Instala proteção contra remoção acidental |
| `launchpad-repositories` | Adiciona PPAs do Launchpad |
| `git-dot-files` | Clona repositórios git ou tarballs para dentro do rootfs |
| `pkexec-sudo-white-list` | Configura whitelist do PolicyKit |
| `pin-packages` | Fixa pacotes em repositórios específicos |
| `install-deb-packages` | Instala pacotes `.deb` externos |
| `install-apt-packages` | Instala pacotes via APT |
| `install-flatpak-packages` | Instala pacotes Flatpak |
| `install-appimage-packages` | Instala pacotes AppImage |
| `install-snap-packages` | Instala pacotes Snap |
| `setup-calamares` | Configura o instalador Calamares |
| `remove-packages-contents` | Remove conteúdo de pacotes específicos |
| `reorganize-menu` | Oculta e reorganiza aplicativos no menu |
| `apply-mitai-directory` | Aplica a estrutura de diretórios do Mita'i OS |
| `apply-mitai-root-ux` | Aplica ajustes de UX na raiz do sistema |
| `remove-system-files` | Remove arquivos do sistema conforme lista |
| `install-electron` | Instala o Electron.js |
| `create-symlinks` | Cria links simbólicos |
| `branding` | Gera arquivos de identidade da distro |
| `make-executable` | Define permissões de execução em arquivos |
| `cleanup-system-image` | Limpa cache APT e logs |
| `umount-virtual-fs` | Desmonta os sistemas de arquivos virtuais |
| `build-squashfs` | Comprime o sistema em squashfs |
| `build-grub` | Gera o bootloader GRUB (BIOS e EFI) |
| `build-iso` | Gera o arquivo ISO final |

### Executar uma etapa individualmente

Após realizar ao menos um build completo, é possível executar etapas isoladas:

```bash
sudo -EH bash build.sh [variante] [etapa]
```

Exemplo — recomprimir somente o squashfs:

```bash
sudo -EH bash build.sh minimal build-squashfs
```

## Opções avançadas

### Entrar no ambiente chroot interativamente

```bash
sudo -EH bash build.sh [variante] --enter-chroot
```

### Executar um comando dentro do chroot

```bash
sudo -EH bash build.sh [variante] --chroot [comando] [arg1] [arg2] ...
```

Exemplo:

```bash
sudo -EH bash build.sh minimal --chroot apt list --installed
```

### Pular etapas do build

```bash
sudo -EH bash build.sh [variante] --skip="[etapa1],[etapa2],[etapa3]"
```

Exemplo — pular instalação de Flatpak e Snap:

```bash
sudo -EH bash build.sh minimal --skip="install-flatpak-packages,install-snap-packages"
```

### Exibir a ajuda

```bash
sudo -EH bash build.sh --help
```

## Saída

Ao final do build bem-sucedido, a ISO gerada estará em:

```
[variante]/iso/[name]-amd64.iso
[variante]/iso/[name]-amd64.md5
```

Onde `[name]` corresponde à variável `name` definida no `distro.ini`.

## Notas

- O script **precisa** ser executado no mesmo diretório onde estão `build.sh` e `data/`. Ele faz `cd` automaticamente para seu próprio diretório ao iniciar.
- O diretório de trabalho do build fica em `[variante]/chroot/` e pode ocupar vários gigabytes.
- Em caso de interrupção, o script tenta desmontar os sistemas de arquivos virtuais automaticamente via trap `EXIT`.
- Variantes com um arquivo `BuildSteps` customizado executam apenas as etapas listadas nele, em ordem.
