# Mosquitto MQTT broker for riscv64: the official eclipse-mosquitto image has no riscv64 build,
# but Debian has the package. Needed by the Frigate integration in Home Assistant.
ARG DEBIAN=trixie
FROM debian:${DEBIAN}-slim
RUN apt-get update && apt-get install -y --no-install-recommends mosquitto \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /mosquitto/config /mosquitto/data /mosquitto/log \
 && printf 'listener 1883\nallow_anonymous true\npersistence true\npersistence_location /mosquitto/data/\n' \
      > /mosquitto/config/mosquitto.conf \
 && chown -R mosquitto:mosquitto /mosquitto
EXPOSE 1883
CMD ["mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]
