# encode: UTF-8

def json_init request,args,session,event
  data={type: :register_table, data: NRF24::register_table }
  return ["application/json",data]
end
