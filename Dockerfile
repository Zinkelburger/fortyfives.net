FROM elixir:1.16-alpine

# Install build dependencies
RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache \
      build-base \
      gcc \
      git \
      make \
      libc-dev \
      bash \
      inotify-tools \
      postgresql-client \
      erlang-dev

# Set the working directory inside the container
WORKDIR /app

# Install hex, rebar, and the Phoenix framework itself
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix archive.install hex phx_new 1.5.9 --force

# Copy over all the necessary application files and directories
COPY config/ config/
COPY lib/ lib/
COPY priv/ priv/
COPY assets/ assets/
COPY mix.exs .
COPY mix.lock .

# Fetch the application dependencies and compile the app
RUN mix do deps.get, deps.compile, compile

# Digest the static assets
RUN mix phx.digest

# Copy the entrypoint script to the container
COPY entrypoint.sh /app/entrypoint.sh

# Make the script executable
RUN chmod +x /app/entrypoint.sh

# Expose port 4000 for the app
EXPOSE 4000

# Use the entrypoint script to run migrations and then start the Phoenix server
ENTRYPOINT ["/app/entrypoint.sh"]
