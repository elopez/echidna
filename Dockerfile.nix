FROM alpine AS builder

# Based on NixOS/docker Dockerfile. Copied as it does not offer an aarch64 build at this time

# Enable HTTPS support in wget and set nsswitch.conf to make resolution work within containers
RUN apk add --no-cache --update openssl git \
  && echo hosts: files dns > /etc/nsswitch.conf

# Download Nix and install it into the system.
ARG NIX_VERSION=2.3.15
RUN wget https://nixos.org/releases/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}-$(uname -m)-linux.tar.xz \
  && tar xf nix-${NIX_VERSION}-$(uname -m)-linux.tar.xz \
  && addgroup -g 30000 -S nixbld \
  && for i in $(seq 1 30); do adduser -S -D -h /var/empty -g "Nix build user $i" -u $((30000 + i)) -G nixbld nixbld$i ; done \
  && mkdir -m 0755 /etc/nix \
  && echo -e 'sandbox = false\nfilter-syscalls = false' > /etc/nix/nix.conf \
  && mkdir -m 0755 /nix && USER=root sh nix-${NIX_VERSION}-$(uname -m)-linux/install \
  && ln -s /nix/var/nix/profiles/default/etc/profile.d/nix.sh /etc/profile.d/ \
  && rm -r /nix-${NIX_VERSION}-$(uname -m)-linux* \
  && rm -rf /var/cache/apk/* \
  && /nix/var/nix/profiles/default/bin/nix-collect-garbage --delete-old \
  && /nix/var/nix/profiles/default/bin/nix-store --optimise \
  && /nix/var/nix/profiles/default/bin/nix-store --verify --check-contents

ENV \
    ENV=/etc/profile \
    USER=root \
    PATH=/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/default/sbin:/bin:/sbin:/usr/bin:/usr/sbin \
    GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt \
    NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

COPY . /echidna/
WORKDIR /echidna

RUN NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 nix-build default.nix --cores 2 --max-jobs 2 --arg tests false

RUN apk add --no-cache --update py3-pip \
  && pip install --no-cache exodus-bundler

RUN exodus --tarball /nix/store/*-echidna-*/bin/echidna-test --output out.tgz \
  && tar xf out.tgz -C /opt/

FROM ubuntu:bionic AS final
ENV PREFIX=/usr/local HOST_OS=Linux
WORKDIR /root
COPY --from=builder /opt/ /opt/
COPY .github/scripts/install-crytic-compile.sh .github/scripts/install-crytic-compile.sh
COPY .github/scripts/solc-qemu.sh /root/.local/bin/
RUN apt-get update && apt-get -y upgrade && apt-get install -y wget locales-all locales python3.6 python3-pip python3-setuptools && apt-get clean
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.6 10
RUN pip3 install solc-select \
  && solc-select install all
RUN if [ $(uname -m) = "aarch64" ]; then \
      apt-get -y install qemu-user libc6-amd64-cross && apt-get clean; \
      for i in ~/.solc-select/artifacts/*; do \
        mv $i $i.amd64; \
        ln -s /root/.local/bin/solc-qemu.sh $i; \
      done; \
    fi
RUN solc-select use 0.8.4
RUN .github/scripts/install-crytic-compile.sh
RUN update-locale LANG=en_US.UTF-8 && locale-gen en_US.UTF-8
ENV PATH=$PATH:/opt/exodus/bin:/root/.local/bin LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
CMD ["/bin/bash"]
