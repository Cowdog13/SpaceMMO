# Dedicated server image for a cheap Linux VPS.
#   docker build -t spacemmo .
#   docker run -d --name spacemmo -p 7777:7777/udp -v spacemmo_data:/data spacemmo
FROM debian:bookworm-slim
ARG GODOT_VERSION=4.3
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 \
 && wget -q https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip \
 && unzip Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip && mv Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
 && rm -f *.zip && apt-get purge -y wget unzip && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
WORKDIR /game
COPY . .
RUN godot --headless --path . --import || true
EXPOSE 7777/udp
VOLUME /data
CMD ["godot", "--headless", "--path", ".", "--", "--server", "--data", "/data"]
