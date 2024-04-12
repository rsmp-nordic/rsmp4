defprotocol RSMP.Service do
  def name(service)
  def status(service, code)
  def ingoing(service, code, args)

  def command(service, path, data, properties)
  def reaction(service, path, data, properties)
end
