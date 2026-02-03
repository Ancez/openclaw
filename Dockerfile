FROM node:22-bookworm

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable && corepack prepare yarn@stable --activate

# Add PostgreSQL 16 repo
RUN apt-get update && \
    apt-get install -y --no-install-recommends gnupg wget lsb-release && \
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -

# Install PostgreSQL 16, Redis 7, Ruby build tools, and sudo
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      postgresql-16 \
      postgresql-client-16 \
      redis-server \
      sudo \
      build-essential \
      git \
      curl \
      wget \
      libssl-dev \
      libreadline-dev \
      zlib1g-dev \
      libpq-dev \
      libyaml-dev \
      libgdbm-dev \
      libncurses5-dev \
      libffi-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Configure PostgreSQL 16
RUN echo "host all all 127.0.0.1/32 md5" >> /etc/postgresql/16/main/pg_hba.conf && \
    echo "host all all ::1/128 md5" >> /etc/postgresql/16/main/pg_hba.conf && \
    echo "listen_addresses='127.0.0.1'" >> /etc/postgresql/16/main/postgresql.conf

# Install RVM and Ruby 3.4.7 (matching autoplay.yml)
RUN gpg --keyserver keyserver.ubuntu.com --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB 2>/dev/null || \
    curl -sSL https://rvm.io/mpapis.asc | gpg --import - && \
    curl -sSL https://rvm.io/pkuczynski.asc | gpg --import -
RUN curl -sSL https://get.rvm.io | bash -s stable
ENV PATH="/usr/local/rvm/bin:${PATH}"
RUN bash -c "source /usr/local/rvm/scripts/rvm && \
    rvm install 3.4.7 && \
    rvm use 3.4.7 --default && \
    gem install bundler foreman --no-document"

# Make RVM available system-wide
RUN echo 'source /usr/local/rvm/scripts/rvm' >> /etc/bash.bashrc

# Install bundler and foreman as system gems (not via RVM) for easier access
RUN bash -c "source /usr/local/rvm/scripts/rvm && rvm use 3.4.7 && \
    gem install bundler foreman --no-document" && \
    ln -sf /usr/local/rvm/wrappers/ruby-3.4.7/ruby /usr/local/bin/ruby && \
    ln -sf /usr/local/rvm/wrappers/ruby-3.4.7/gem /usr/local/bin/gem && \
    ln -sf /usr/local/rvm/wrappers/ruby-3.4.7/bundle /usr/local/bin/bundle && \
    ln -sf /usr/local/rvm/wrappers/ruby-3.4.7/foreman /usr/local/bin/foreman

# Install NVM and Node 24.x (matching autoplay.yml)
ENV NVM_DIR="/usr/local/nvm"
RUN mkdir -p $NVM_DIR && \
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
RUN bash -c "export NVM_DIR='$NVM_DIR' && \
    [ -s '$NVM_DIR/nvm.sh' ] && \. '$NVM_DIR/nvm.sh' && \
    nvm install 24 && \
    nvm alias default 24 && \
    nvm use default"
# Set Node 24 as default (override system node) - use wildcard for exact version
RUN ln -sf $NVM_DIR/versions/node/v24*/bin/node /usr/local/bin/node24 && \
    ln -sf $NVM_DIR/versions/node/v24*/bin/npm /usr/local/bin/npm24 && \
    ln -sf $NVM_DIR/versions/node/v24*/bin/npx /usr/local/bin/npx24
ENV PATH="/usr/local/rvm/wrappers/ruby-3.4.7:$PATH"

WORKDIR /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --frozen-lockfile

COPY . .
RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Allow non-root user to write temp files during runtime/tests.
RUN chown -R node:node /app

# Security hardening: Run as non-root user
# The node:22-bookworm image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges

# Setup for node user with sudo access for services
RUN mkdir -p /home/node/.nvm /home/node/.rvm && \
    chown -R node:node /home/node && \
    usermod -aG postgres node && \
    echo "node ALL=(postgres) NOPASSWD: /usr/lib/postgresql/16/bin/pg_ctl" >> /etc/sudoers && \
    echo "node ALL=(ALL) NOPASSWD: /usr/bin/redis-server" >> /etc/sudoers

# Initialize PostgreSQL 16 database cluster
RUN rm -rf /var/lib/postgresql/16/main/* && \
    su - postgres -c "/usr/lib/postgresql/16/bin/initdb -D /var/lib/postgresql/16/main -E UTF8" && \
    su - postgres -c "mkdir -p /var/lib/postgresql/16/main/pg_log" && \
    su - postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/logfile start" && \
    sleep 2 && \
    su - postgres -c "psql -c \"CREATE USER node WITH SUPERUSER PASSWORD 'node';\"" && \
    su - postgres -c "psql -c \"CREATE DATABASE node OWNER node;\"" && \
    su - postgres -c "psql -c \"CREATE DATABASE sprintflint_rails_development OWNER node;\"" && \
    su - postgres -c "psql -c \"CREATE DATABASE sprintflint_rails_test OWNER node;\"" && \
    su - postgres -c "psql -c \"ALTER USER postgres PASSWORD 'postgres';\"" && \
    su - postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main stop"

USER node

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","dist/index.js","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "dist/index.js", "gateway", "--allow-unconfigured"]
