# Debian 13 (Trixie) distroless for minimal attack surface
# Note: Using 'static' instead of 'static-debian13:nonroot' so we can run as root
# Port 69 (TFTP) requires privileged port binding
FROM gcr.io/distroless/static-debian13

WORKDIR /app

# Copy pre-built binary
COPY bootimus /app/bootimus

# Expose ports
EXPOSE 69/udp 8080/tcp 8081/tcp

# Run as root (required for port 69)
# Alternative: Run with --cap-add NET_BIND_SERVICE and use non-root user
USER root

ENTRYPOINT ["/app/bootimus"]
CMD ["serve"]
