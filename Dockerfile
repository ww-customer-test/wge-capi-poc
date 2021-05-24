FROM ubuntu:focal

ARG DEBIAN_FRONTEND=noninteractive
ARG WKP_VERSION='v2.5.0'
ENV K8S_VERSION="v1.19.0"

# Install updates
RUN echo "\
      deb http://archive.ubuntu.com/ubuntu focal main restricted universe multiverse\n\
      deb http://archive.ubuntu.com/ubuntu focal-updates main restricted universe multiverse\n\
      deb http://archive.ubuntu.com/ubuntu focal-security main restricted universe multiverse" \
      > /etc/apt/sources.list \
      && apt-get -y update \
      && apt-get -y upgrade


RUN apt-get -y install software-properties-common \
      curl \
      wget \
      sudo \
      vim \
      git \
      npm \
      s3cmd \
      && apt-get autoclean \
      && apt-get autoremove

RUN curl -L https://storage.googleapis.com/kubernetes-release/release/v1.19.0/bin/linux/amd64/kubectl -o /bin/kubectl && chmod +x /bin/kubectl
RUN curl -L https://github.com/jkcfg/jk/releases/download/0.4.0/jk-linux-amd64 -o /bin/jk && chmod +x /bin/jk


RUN curl -O https://weaveworks-wkp-releases.s3.amazonaws.com/wk-v2.5.0.tgz

RUN tar -zxvf wk-v2.5.0.tgz \
    && chmod +x wk-v2.5.0-linux-amd64 \
    && rm wk-v2.5.0.tgz \
    && rm wk-v2.5.0-darwin-amd64 \
    && mv wk-v2.5.0-linux-amd64 /bin/wk

COPY scripts/ /scripts

RUN chmod +x /scripts/*