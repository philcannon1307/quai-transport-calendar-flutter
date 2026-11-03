# Railway builds this image from the /server folder (Root Directory = /server).
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
# No npm install step: the service has zero third-party dependencies.
COPY package.json ./
COPY src ./src
COPY scripts ./scripts
USER node
EXPOSE 3000
CMD ["node", "src/server.js"]
