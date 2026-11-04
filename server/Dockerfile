# Railway builds this image from the /server folder (Root Directory = /server).
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
# One runtime dependency (pg). Lockfile install = reproducible build.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
COPY scripts ./scripts
COPY db ./db
USER node
EXPOSE 3000
CMD ["node", "src/server.js"]
