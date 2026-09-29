FROM python:3.12-alpine
WORKDIR /app
COPY server.py .
COPY public ./public
ENV PORT=8080
EXPOSE 8080
CMD ["python", "server.py"]
