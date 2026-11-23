# Use the slim Alpine image
FROM nginx:1.30-alpine-slim

# Replace the default nginx config with our frontend config
COPY frontend.nginx.conf /etc/nginx/nginx.conf

# The config makes nginx listen on 8080 
EXPOSE 8080

# Keep NGINX running in the foreground (default in official image)
CMD ["nginx", "-g", "daemon off;"]