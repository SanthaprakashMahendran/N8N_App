FROM n8nio/n8n:1.63.4

USER root

RUN apk add --no-cache \
    curl \
    jq \
    vim \
    python3 \
    py3-pip

USER node
