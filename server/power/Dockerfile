FROM python:3.12-alpine
RUN pip install --no-cache-dir "tinytuya>=1.13,<2" && adduser -D -u 10001 rdpower
COPY rd_power.py /app/rd_power.py
USER rdpower
EXPOSE 8090
CMD ["python", "-u", "/app/rd_power.py"]
