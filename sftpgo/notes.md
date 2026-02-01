````nginx configuration
stream {
    server {
        listen 2022;
        proxy_pass sftpgo:2022;
        proxy_protocol on;
    }
}
````

- für SFTP public key / Zertifikat verwenden