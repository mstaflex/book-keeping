FROM alpine:3.19
COPY entrypoint.sh /entrypoint.sh
# CR-Zeichen entfernen: ein Windows-Checkout mit CRLF würde sh sonst abbrechen lassen
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh
CMD ["sh", "/entrypoint.sh"]
