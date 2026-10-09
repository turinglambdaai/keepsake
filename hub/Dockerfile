# Keepsake Hub — the self-hosted repository center.
# Build:  docker build -t keepsake-hub hub/
# Run:    docker run -d -p 8080:8080 -v /mnt/user/keepsake:/data \
#           -e KEEPSAKE_HUB_TOKEN=change-me keepsake-hub
FROM racket/racket:9.3

RUN raco pkg install --auto --no-docs crypto

WORKDIR /hub
COPY app/ /hub/app/
COPY hub/ /hub/hub/

ENV KEEPSAKE_HUB_REPO_ROOT=/data
ENV KEEPSAKE_HUB_PORT=8080
VOLUME ["/data"]
EXPOSE 8080

ENTRYPOINT ["racket", "hub/server.rkt"]
