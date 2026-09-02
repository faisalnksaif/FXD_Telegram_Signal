curl -X POST http://165.22.209.234:5000/api/signals/test \
  -H "Content-Type: application/json" \
  -d '{"type":"SIGNAL_ALERT","symbol":"XAUUSD","direction":"BUY","entry":4377.78,"sl":4368.50,"tp1":4386.42,"tp2":4396.38,"tp3":4406.48}'
