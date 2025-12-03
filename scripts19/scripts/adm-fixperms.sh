#!/usr/bin/env bash
# Módulo: adm-fixperms
#
# Normaliza permissões de um diretório DESTDIR de pacote.
# Regras principais (pensadas para LFS / FHS):
#   - diretórios: 755 por padrão (exceto raízes sensíveis)
#   - binários em bin/sbin: 755
#   - libs .so*: 755
#   - libs .a, .la: 644
#   - headers em include/: 644
#   - man, info, doc: 644
#   - arquivos regulares não-executáveis: 644
#
# Não mexemos em:
#   - /dev, /proc, /sys, /run
#   - /var/log/*
#   - /tmp, /var/tmp
#   - /root (não derruba permissões mais restritas)
#
# Controle:
#   - ADM_DISABLE_FIXPERMS=1 desativa o módulo
#   - ADM_FIXPERMS_VERBOSE=1 mostra tudo que está sendo alterado

adm_fixperms() {
  local root="$1"

  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "adm-fixperms: DESTDIR inválido: '$root'" >&2
    return 1
  fi

  if [ "${ADM_DISABLE_FIXPERMS:-0}" = "1" ]; then
    echo "adm-fixperms: desativado (ADM_DISABLE_FIXPERMS=1)" >&2
    return 0
  fi

  local vflag=""
  [ "${ADM_FIXPERMS_VERBOSE:-0}" = "1" ] && vflag="-v"

  echo "adm-fixperms: normalizando permissões em: $root"

  ########################################
  # 1) Diretórios: padrão 755
  ########################################
  # Excluímos alguns caminhos sensíveis.
  find "$root" -xdev -type d \
    ! -path "$root/proc*" \
    ! -path "$root/sys*" \
    ! -path "$root/dev*" \
    ! -path "$root/run*" \
    ! -path "$root/tmp" \
    ! -path "$root/tmp/*" \
    ! -path "$root/var/tmp" \
    ! -path "$root/var/tmp/*" \
    ! -path "$root/var/log" \
    ! -path "$root/var/log/*" \
    ! -path "$root/root" \
    $vflag -exec chmod 755 {} + 2>/dev/null || true

  ########################################
  # 2) Libs
  ########################################

  # Shared libs: lib*.so, lib*.so.*
  find "$root" -xdev -type f \
    \( -name 'lib*.so' -o -name 'lib*.so.*' \) \
    $vflag -exec chmod 755 {} + 2>/dev/null || true

  # Static libs (.a) e libtool (.la) -> 644
  find "$root" -xdev -type f \
    \( -name 'lib*.a' -o -name 'lib*.la' \) \
    $vflag -exec chmod 644 {} + 2>/dev/null || true

  ########################################
  # 3) Binários em paths padrão
  ########################################

  local bindirs=(
    "$root/bin"
    "$root/sbin"
    "$root/usr/bin"
    "$root/usr/sbin"
    "$root/usr/local/bin"
    "$root/usr/local/sbin"
  )

  for d in "${bindirs[@]}"; do
    if [ -d "$d" ]; then
      find "$d" -xdev -type f ! -type l \
        $vflag -exec chmod 755 {} + 2>/dev/null || true
    fi
  done

  ########################################
  # 4) Scripts com shebang (#!) em qualquer lugar
  ########################################
  # Se começa com "#!", forçamos 755.
  find "$root" -xdev -type f ! -type l \
    -exec sh -c '
      f="$1"
      # Ignora binários já marcados com execute
      if [ -x "$f" ]; then
        exit 0
      fi
      head -c 2 "$f" 2>/dev/null | grep -q "^#!" || exit 0
      chmod '"${vflag:+-v}"' 755 "$f" 2>/dev/null || true
    ' _ {} \; 2>/dev/null || true

  ########################################
  # 5) Headers em include/ -> 644
  ########################################

  if [ -d "$root/usr/include" ]; then
    find "$root/usr/include" -xdev -type f ! -type l \
      \( -name '*.h' -o -name '*.hpp' -o -name '*.hh' \) \
      $vflag -exec chmod 644 {} + 2>/dev/null || true
  fi

  ########################################
  # 6) Manpages, info, doc -> 644
  ########################################

  # man
  if [ -d "$root/usr/share/man" ]; then
    find "$root/usr/share/man" -xdev -type f ! -type l \
      $vflag -exec chmod 644 {} + 2>/dev/null || true
  fi

  # info
  if [ -d "$root/usr/share/info" ]; then
    find "$root/usr/share/info" -xdev -type f ! -type l \
      $vflag -exec chmod 644 {} + 2>/dev/null || true
  fi

  # doc
  if [ -d "$root/usr/share/doc" ]; then
    find "$root/usr/share/doc" -xdev -type f ! -type l \
      $vflag -exec chmod 644 {} + 2>/dev/null || true
  fi

  ########################################
  # 7) Arquivos em /etc (config)
  ########################################
  # Regra padrão: 644, exceto se já forem mais restritos.
  if [ -d "$root/etc" ]; then
    find "$root/etc" -xdev -type f ! -type l \
      ! -name 'shadow' ! -name 'gshadow' \
      -exec sh -c '
        f="$1"
        # se já é 600/640/644 etc, respeitamos apenas se não estiver muito aberto
        # Forçamos u=rw,go=r
        chmod u=rw,go=r "$f" 2>/dev/null || true
      ' _ {} \; 2>/dev/null || true

    # Se um pacote criar shadow/gshadow, garante 600
    for sens in shadow gshadow; do
      if [ -f "$root/etc/$sens" ]; then
        chmod $vflag 600 "$root/etc/$sens" 2>/dev/null || true
      fi
    done
  fi

  ########################################
  # 8) Arquivos regulares não-executáveis genéricos -> 644
  ########################################
  # (Isso é o “fallback”: o que não entrou nas regras acima
  #  e não tem bit de execução, forçamos 644.)
  find "$root" -xdev -type f ! -type l \
    ! -perm -111 \
    $vflag -exec chmod 644 {} + 2>/dev/null || true

  echo "adm-fixperms: concluído em $root"
}
