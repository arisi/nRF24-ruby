# encode: UTF-8

def json_nRF24 request,args,session,event
  if not session or session==0
    return ["text/event-stream",{}]
  end
  #sleep 3
  data=NRF24::json
  return ["text/event-stream",data]
end
