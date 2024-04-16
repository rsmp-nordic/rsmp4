defprotocol RSMP.Service.Protocol do
  def status(service, node, path)
  def command(service, node, path, payload, properties)
  def reaction(service, node, path, payload, properties)
end

