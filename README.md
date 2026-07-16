# noadr
<!--
[![Package Version](https://img.shields.io/hexpm/v/noadr)](https://hex.pm/packages/noadr)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/noadr/)
-->

Nord Pool Day-ahead electricity prices to OpenADR 3 bridge.

In order to run this you will need to have Gleam [installed](https://gleam.run/install/).
```sh
git clone https://github.com/karlsson/noadr.git
cd noadr
gleam run
```
Will start a webserver listening on port 8000 on localhost.
Currently only events with id for AREAs are implemented, e.g.
`http://localhost:8000/events/SE3` will fetch Day-ahead prices from
Nord Pool server for area SE3 and convert to OpenADR 3 format.
It will fetch both todays prices and, if available, tomorrows prices. Nord Pool prices are divided into 15 min intervals for a 24 hour period.

OpenADR "Programs" will be added so that all areas can be known.
To see available areas for now, check the Nord Pool [Day-ahead](https://data.nordpoolgroup.com/auction/day-ahead/prices?deliveryDate=latest&currency=SEK&aggregation=DeliveryPeriod&deliveryAreas=DK1,DK2,FI,NO1,NO2,NO3,NO4,NO5,SE1,SE2,SE3,SE4) page.

**NOTE** : This is really alpha version and request/reply formats may change.

Todos:
* Cache fetched price data.
* Add OpenADR enumerations for event payload and program attribute values maps (oadr3 library).
* Add OpenADR Programs.
* Current prices is from Energy providers but a large part of the total price is added by the Grid net owners, so some means to incorporate these would be interesting.
* ..


Inspired by Don Jackson's [Grid Coordination](https://github.com/grid-coordination/price-server-user-guide) price server.
<!--
```gleam
import noadr

pub fn main() -> Nil {
  // TODO: An example of the project in use
}
```

Further documentation can be found at <https://hexdocs.pm/noadr>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
-->
