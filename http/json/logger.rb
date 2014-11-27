# encode: UTF-8

def json_logger request,args,session,event
  if not session or session==0
    return ["text/event-stream",{}]
  end
  @http_sessions[session][:log_pos]=0 if not @http_sessions[session][:log_pos]
  size=NRF24::get_log.size
  if @http_sessions[session][:log_pos]!=size
    if size-@http_sessions[session][:log_pos]>30
      @http_sessions[session][:log_pos]=size-30
    end
    loglines=NRF24::get_log[@http_sessions[session][:log_pos],size-@http_sessions[session][:log_pos]]
    @http_sessions[session][:log_pos]=size
  else
    loglines=[]
  end

  data={
  	loglines: loglines,
  	session: session,
  	event: event,
  	}
  return ["text/event-stream",data]
end
