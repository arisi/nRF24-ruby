regs={}

logger = (data) ->
  console.log "log>",data
  if data.event==0
    $(".log").html("alku\n")
  for l in data.loglines
    #console.log l
    $(".log").prepend(l.text+"\n")  


dev = (d,obj) ->
  #ret+="<td>#{obj.scnt}<td>"
  for k in ['rcnt','rfull','scnt']
      $("#d#{d}r#{k}").html obj[k]
  for k,v of obj.regs
    if (v instanceof Array)
      $("#d#{d}r#{k}").html "--"
    else
      $("#d#{d}r#{k}").html (0x100+v).toString(2).substring(1,9)

update_status = (data) ->
  #console.log data
  $(".info").html(data.now)
  dev(0,data.devs[0])
  dev(1,data.devs[1])

@build_regs = (regs) ->
  ret="<table>"
  for k,v of regs
    ret+="<tr>"
    ret+="<td >#{v}<td>"
    ret+="<td id='d0r#{k}'>d0r#{k}<td>"
    ret+="<td id='d1r#{k}'>d1r#{k}<td>"
    ret+="</tr>"
  ret+="</table>"
  $(".regs").html(ret)
  ret="<table>"
  for k in ['rcnt','rfull','scnt']
    ret+="<tr>"
    ret+="<td >#{k}<td>"
    ret+="<td id='d0r#{k}'>d0r#{k}<td>"
    ret+="<td id='d1r#{k}'>d1r#{k}<td>"
    ret+="</tr>"
  ret+="</table>"
  $(".stats").html(ret)

@process_data = (obj) ->
  console.log "process",obj,obj.type
  if obj.type == "register_table"
    console.log "is table",obj.data
    for k,v of  obj.data
      console.log k,v.address
      regs[v.address]=k
  build_regs regs
  
@ajaxform = (obj) ->
  console.log "doin ajax"
  form=$(obj).closest("form")
  key=form.attr('id')
  q=$( form ).serialize()
  console.log q
  $.ajax
    url: "/action.json?#{q}"
    type: "GET"
    processData: false
    contentType: false
    success: (data) ->
      console.log "ajax returns: ", data
      
      return
    error: (xhr, ajaxOptions, thrownError) ->
      alert thrownError
      return

@ajax = (url,obj) ->
  console.log "doin ajax"
  $.ajax
    url: url
    type: "GET"
    processData: false
    contentType: false
    success: (data) ->
      console.log "ajax returns: ", data
      process_data(data)
      return
    error: (xhr, ajaxOptions, thrownError) ->
      alert thrownError
      return

$ ->
  console.log "nRF24 Starts"
  #update_gw()
  #setInterval(->
  #  update_gw()
  #  return
  #, 200000)
  ajax("/init.json",[])
  stream = new EventSource("/nRF24.json")
  stream.addEventListener "message", (event) ->
    update_status($.parseJSON(event.data))
    return
  stream = new EventSource("/logger.json")
  stream.addEventListener "message", (event) ->
    logger($.parseJSON(event.data))
    return