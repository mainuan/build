<div align="center">

<img src="https://raw.githubusercontent.com/mainuan/.github/main/profile/assets/mainuan-logo.svg" width="96" alt="Logotipo do Mainuan">

# Mainuan ISO Builder

Construtor da imagem ISO oficial do **Mainuan Linux**, baseada no Kubuntu 26.04 LTS e no KDE Plasma 6.6.

[![ISO](https://github.com/mainuan/build/actions/workflows/build-iso.yml/badge.svg)](https://github.com/mainuan/build/actions/workflows/build-iso.yml)
[![Release](https://img.shields.io/github/v/release/mainuan/build?include_prereleases&label=release)](https://github.com/mainuan/build/releases)
![Base](https://img.shields.io/badge/base-Kubuntu%2026.04%20LTS-0079c1)
![Plasma](https://img.shields.io/badge/KDE%20Plasma-6.6-1d99f3)
[![Licença](https://img.shields.io/github/license/mainuan/build)](LICENSE)
![Arquitetura](https://img.shields.io/badge/arquitetura-amd64%20(x86--64%20b%C3%A1sico)-555)

</div>

---

## O que é

O `build.sh` parte da ISO oficial do Kubuntu e aplica a variante Mainuan:

1. **Extrai** o sistema de arquivos (`casper/filesystem.squashfs`).
2. **Personaliza** num chroot: remove pacotes, instala os aplicativos Mainuan, aplica temas, ícones, wallpapers e configurações padrão, configura o Calamares e a identidade do sistema.
3. **Gera** uma ISO híbrida, que inicia por BIOS e UEFI, em pendrive ou DVD.

Cada fonte externa é **fixada e verificada**:

- a ISO base é conferida pelo `SHA256SUMS` assinado pelo Ubuntu;
- cada `.deb` é conferido pelo SHA-256;
- cada recurso git é baixado num commit exato.

O mesmo commit do construtor gera sempre a mesma composição de componentes.

```
Kubuntu 26.04.1 (GPG + SHA-256) ──┐
.deb dos aplicativos (SHA-256) ───┼──▶ build.sh ──▶ mainuan-2027.1-rc7-amd64.iso
temas/ícones/wallpapers (commit) ─┘                 ├─ .sha256, .packages, .build-info
                                                    └─ testes: estrutura, boot UEFI e BIOS
```

## Download

As ISOs testadas são publicadas em **[Releases](https://github.com/mainuan/build/releases)**. Cada arquivo de release no GitHub tem limite de 2 GiB, então a ISO vem em partes:

```bash
sha256sum --check --ignore-missing SHA256SUMS      # confere as partes
cat mainuan-*-amd64.iso.part* > mainuan.iso        # remonta
sha256sum --check --ignore-missing SHA256SUMS      # confere a ISO inteira
```

Também é possível baixar pelo site oficial: <https://mainuan.com.br>.

## Construir localmente

Requisitos: host Ubuntu/Kubuntu (26.04 recomendado), cerca de 50 GB livres, acesso root e internet. As ferramentas que faltarem (`xorriso`, `squashfs-tools`, `grub-*`, `mtools`, `gnupg`…) são instaladas pelo próprio script.

```bash
git clone https://github.com/mainuan/build.git
cd build
sudo --preserve-env=PWD,XDG_RUNTIME_DIR,XDG_DATA_DIRS,PATH ./build.sh base
```

> [!IMPORTANT]
> O construtor precisa de pelo menos as variáveis de ambiente `PWD`, `XDG_RUNTIME_DIR`, `XDG_DATA_DIRS` e `PATH` como sendo iguais entre o ambiente root e o usuário que usou o comando `sudo`, do contrario poderá causar corrupção de memória no `bwrap` o utilitário que realiza a instalação de pacotes Flatpak.

Resultado em `base/iso/`:

| Arquivo | Conteúdo |
|---|---|
| `mainuan-2027.1-rc7-amd64.iso` | imagem final |
| `….iso.sha256` | SHA-256 da imagem |
| `….packages` | todos os pacotes instalados (nome, versão, arquitetura) |
| `….build-info` | base, commit do construtor, versões de kernel, Plasma, Qt e Calamares |
| `components.sha256` | hash de cada componente externo usado |
| `components.sha256.insecure` | hash de cada componente externo usado no qual não foi possivel obter uma hash oficial |

Com `--iso=/caminho/kubuntu-26.04.1-desktop-amd64.iso`, o download é evitado. O arquivo ainda precisa ter o SHA-256 fixado.

### Etapas

O build executa as funções `function …` do `build.sh` na ordem em que aparecem. Cada etapa roda com `errexit`: o primeiro erro interrompe tudo e informa a etapa, a linha e o comando.

| Comando | Descrição |
|---|---|
| `sudo ./build.sh --preserve-env=PWD,XDG_RUNTIME_DIR,XDG_DATA_DIRS,PATH base build-squashfs` | Repete uma etapa (após um build completo). |
| `sudo ./build.sh --preserve-env=PWD,XDG_RUNTIME_DIR,XDG_DATA_DIRS,PATH base --enter-chroot` | Abre um shell dentro da imagem. |
| `sudo ./build.sh --preserve-env=PWD,XDG_RUNTIME_DIR,XDG_DATA_DIRS,PATH base --chroot apt list --installed` | Executa um comando dentro do chroot. |
| `sudo ./build.sh --preserve-env=PWD,XDG_RUNTIME_DIR,XDG_DATA_DIRS,PATH --skip=install-flatpak-packages base` | Pula uma etapa do processo de build. |


| Etapa | O que faz |
|---|---|
| `check-build-dependencies` | instala no host as ferramentas que faltam |
| `download-image` | baixa a base e confere assinatura e SHA-256 |
| `extract-image` | extrai o squashfs para `chroot/` |
| `prepare-base-image` | teclado, locale `pt_BR`, kernel e casper; trava o x86-64 básico (sem `amd64v3`) |
| `remove-base-packages` | `data/base/remove-base-packages.lst` |
| `launchpad-repositories` / `pin-packages` | PPAs e *pinning* |
| `git-dot-files` | recursos fixados em `git-dot-files.lst` |
| `install-deb-packages` | `.deb` com SHA-256 em `install-deb-packages.lst` |
| `install-apt-packages` / `install-flatpak-packages` | pacotes extras |
| `setup-calamares` | identidade, páginas e partições do instalador |
| `remove-orphan-packages` | `data/base/remove-orphan-packages.lst`: bibliotecas que só a versão antiga de um pacote da base usava; para o build se algo mais sairia junto |
| `remove-packages-contents`, `reorganize-menu`, `remove-system-files`, `create-symlinks` | ajustes de menu e de arquivos |
| `branding` | `os-release`, `lsb-release`, `issue`, "Sobre este sistema" |
| `cleanup-system-image` | confere a ausência de variantes `amd64v3`, limpa APT e logs |
| `write-manifests` | lista de pacotes e informações de build |
| `build-squashfs`, `build-grub`, `build-iso` | squashfs xz, GRUB BIOS/UEFI, ISO e SHA-256 |

**Nota:** Para testes rápidos é possivel pular a verificação de hashes com `sudo ALLOW_INSECURE_PACKAGES=allow_insecure ./build.sh`

### Configuração da variante

Tudo o que define o Mainuan fica em [`data/base/`](data/base):

| Arquivo | Uso |
|---|---|
| `distro.ini` | nome, versão (`2027.1`, estágio `rc7`), usuário Live, locale, links e ISO base fixada (`base_iso_url`, `base_iso_sha256`, `base_iso_signing_key`) |
| `install-deb-packages.lst` | `<URL> <SHA-256>` por linha |
| `git-dot-files.lst` | `<repo>.git <commit> > <destino>` ou `<URL> <SHA-256> > <destino>` |
| `install-apt-packages.lst`, `remove-base-packages.lst` | pacotes adicionados e removidos |
| `remove-orphan-packages.lst` | órfãos deixados pela atualização da base (`libflashrom1`, `libftdi1-2`, `libjcat1` do fwupd 2.1.1), removidos depois das instalações |
| `grub-entries.yaml` | entradas do menu de boot |
| `hide-apps-from-menu.lst`, `reorganize-apps.yaml`, `plasma-kcms.yaml` | menu de aplicativos |

Para trocar a versão de um aplicativo na ISO, publique a release no repositório dele e atualize a linha correspondente em `install-deb-packages.lst`, com a URL e o SHA-256 do asset. O GitHub mostra o hash em cada asset, e `gh release view` também o informa.

## Testes

| Teste | Comando | O que verifica |
|---|---|---|
| Estrutura | `tests/iso/check-iso.sh <iso>` | registros de boot BIOS e UEFI, MBR híbrido, kernel e initrd, `md5sum.txt`, `os-release`, pacotes essenciais e Mainuan, Calamares, ausência de restos de build e de variantes `amd64v3`, `apt-get check` das dependências, órfãos removidos e fwupd mantido |
| Boot Live | `tests/iso/live-smoke.py <iso> --firmware uefi\|bios [--cpu-model Nehalem]` | inicia pelo GRUB da ISO em QEMU/KVM, entra pela serial como o usuário Live e coleta estado do systemd, unidades com falha, sessão Plasma/Wayland, rede, DNS, erros do journal e uma captura de tela; desliga |
| VM local | `tests/vm/mainuan-vm.sh create <iso>` | cria a VM `mainuan-test` no libvirt (UEFI, 4 vCPU, 6 GiB, 60 GB) para instalar pelo Calamares no Virt-Manager |

## Integração contínua

O workflow [`ISO`](.github/workflows/build-iso.yml):

- **lint** em todo push e PR: `bash -n`, ShellCheck e a exigência de que cada fonte esteja fixada;
- **build** completo, executado manualmente, em tags `v*` e em PRs que alteram o construtor: estrutura e boot Live UEFI, UEFI com Secure Boot (shim e GRUB assinados da base Kubuntu) e BIOS, ISO em partes de 1900 MiB e `SHA256SUMS`, com artefato por 14 dias;
- **release** só por tag `v*`, sem nunca substituir uma release existente. RCs são publicadas como *pre-release*.

A tag é a aprovação humana: ela só é criada depois dos testes de instalação na VM.

## Problemas conhecidos

- **Editor do GRUB** fora da ISO: a release atual do `mainuan-grub-editor` não foi gerada pelo CI.
- `setup-anti-breakage` está desativado.

## Créditos

Construtor criado por **Natanael Barbosa Santos** ([@natanael-art](https://github.com/natanael-art)) como *Mita'i OS Builder* e adaptado ao Mainuan por Daigo ([@daigoasuka](https://github.com/daigoasuka)) e Rafael Ruscher ([@ruscher](https://github.com/ruscher)). Base: [Kubuntu](https://kubuntu.org) e [Ubuntu](https://ubuntu.com).

## Licença

GNU General Public License, versão 2 (GPL-2.0). Texto completo em [`LICENSE`](LICENSE).
