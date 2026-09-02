curl -X POST http://165.22.209.234:5000/api/signals/test \
  -H "Content-Type: application/json" \
  -d '{"type":"SIGNAL_ALERT","symbol":"XAUUSD","direction":"SELL","entry":4369.67,"sl":4379.24,"tp1":4363.24,"tp2":4353.71,"tp3":4343.82}'
