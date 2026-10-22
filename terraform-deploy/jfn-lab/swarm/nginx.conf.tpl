# TEMPLATE based on the original nginx.conf (TCP "stream" proxy).
# deploy.sh fills the upstream block below with one server line per Ready worker.
events {
    worker_connections 1024;
}

stream {
    log_format upstreamlog '$remote_addr [$time_local] routed to: $upstream_addr';
    access_log /var/log/nginx/access.log upstreamlog;

    upstream jfn_gateways {
@@SERVERS@@
    }

    server {
        listen 8000;
        proxy_pass jfn_gateways;
        proxy_timeout 30s;
        proxy_connect_timeout 5s;
    }
}
