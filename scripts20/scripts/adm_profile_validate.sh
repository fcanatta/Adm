#!/usr/bin/env bash
# Helper de validação de profile para scripts de pacote do Adm
# Use em cada script com:
#   source /usr/src/adm/lib/adm_profile_validate.sh
#   adm_profile_validate

adm_profile_fail() {
  printf '[profile-validate:%s/%s][ERRO] %s\n' "${ADM_CATEGORY:-?}" "${ADM_PKG_NAME:-?}" "$*" >&2
  exit 1
}

adm_profile_warn() {
  printf '[profile-validate:%s/%s][WARN] %s\n' "${ADM_CATEGORY:-?}" "${ADM_PKG_NAME:-?}" "$*" >&2
}

adm_profile_log() {
  printf '[profile-validate:%s/%s] %s\n' "${ADM_CATEGORY:-?}" "${ADM_PKG_NAME:-?}" "$*" >&2
}

# REQUIRED_LIBCS pode ser, por exemplo:
#   REQUIRED_LIBCS="glibc musl"
# ou
#   REQUIRED_LIBCS="musl"
# se não for definido, não há checagem de tipo de libc
adm_profile_validate() {
  # 1) Variáveis básicas
  : "${ADM_PROFILE_NAME:?ADM_PROFILE_NAME não definido (profile não carregado?).}"
  : "${ADM_LIBC:?ADM_LIBC não definido (profile incorreto?).}"
  : "${ADM_ROOTFS:?ADM_ROOTFS não definido (profile incompleto?).}"
  : "${ADM_PREFIX:?ADM_PREFIX não definido.}"
  : "${ADM_SYSLIBDIR:?ADM_SYSLIBDIR não definido.}"

  # ROOTFS seguro
  if [ "$ADM_ROOTFS" = "/" ]; then
    adm_profile_fail "ADM_ROOTFS é '/', isso não é permitido (risco de destruir o sistema host)."
  fi

  # Sanidade básica de diretórios
  if [ ! -d "$ADM_ROOTFS" ]; then
    adm_profile_warn "ADM_ROOTFS aponta para diretório inexistente: $ADM_ROOTFS"
  fi

  # 2) Libc suportada por este pacote (se definido REQUIRED_LIBCS)
  if [ -n "${REQUIRED_LIBCS:-}" ]; then
    local ok=0 libc
    for libc in $REQUIRED_LIBCS; do
      if [ "$ADM_LIBC" = "$libc" ]; then
        ok=1
        break
      fi
    done
    if [ "$ok" -ne 1 ]; then
      adm_profile_fail "Este pacote requer ADM_LIBC em {${REQUIRED_LIBCS}}, mas o profile atual tem ADM_LIBC='${ADM_LIBC}'."
    fi
  fi

  # 3) Triplet e toolchain (opcional, mas útil)
  if [ -z "${ADM_TRIPLET:-}" ]; then
    adm_profile_warn "ADM_TRIPLET não definido no profile; alguns pacotes podem depender disso."
  fi

  if [ -z "${ADM_TOOLCHAIN_PREFIX:-}" ]; then
    adm_profile_warn "ADM_TOOLCHAIN_PREFIX não definido no profile; usando compilers do PATH."
  else
    if [ ! -d "$ADM_TOOLCHAIN_PREFIX" ]; then
      adm_profile_warn "ADM_TOOLCHAIN_PREFIX aponta para diretório inexistente: $ADM_TOOLCHAIN_PREFIX"
    fi
  fi

  adm_profile_log "Profile '${ADM_PROFILE_NAME}' validado (ADM_LIBC=${ADM_LIBC}, ROOTFS=${ADM_ROOTFS})."
}
