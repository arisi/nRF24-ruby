# encode: UTF-8

def json_nRF24_single request,args,session,event
  data=NRF24::json
  return ["application/json",data]
end

